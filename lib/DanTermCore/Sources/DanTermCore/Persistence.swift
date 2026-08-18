// Model <-> disk: the pure serialization/restore policy, no file I/O. Restore
// (decode + validate an init file from in-memory Data),
// Export (AppModel -> snapshot -> init file, plus scrollback grafting), the
// checkpoint merge (enriched scrollback grafted into a light restore), and
// scrollback truncation. Everything is pure value-mapping: the FileManager/Data
// recovery-path and session-lock I/O that used to tail this file now lives in
// DanTermSupport's RecoveryStore -- the codec stays here, the disk touch moved out.
// Split out of ModelOperations.swift because snapshot/restore/recovery is a large
// cohesive concern distinct from the live-model helpers; `import Foundation` only --
// no AppKit.
import Foundation

// MARK: - Restore

struct ValidatedAppRestore {
  let snapshot: AppModelSnapshot
  let model: AppModel
  let paneSnapshots: [PaneId: PaneSnapshot]
}

enum AppInitFileLoadError: Error, Equatable {
  case decodeFailed
  case unsupportedVersion(Int)
  case invalidSnapshot
}

/// Decode a saved init file and validate that its snapshot can be rebuilt. Takes
/// `env` (defaulting to `.live`) so id-less entries mint reproducible ids and
/// `~`-cwds expand against an injectable home; app restore omits it (live ambient).
func loadValidatedInitFile(from data: Data, env: CoreEnv = .live) throws -> ValidatedAppRestore {
  let initFile: AppInitFile
  do {
    initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
  } catch {
    throw AppInitFileLoadError.decodeFailed
  }

  // Require the current format. Older formats are rejected outright -- no
  // version-dispatch fork or one-shot importer. An old checkpoint
  // on the first post-upgrade launch falls through to a fresh session.
  guard initFile.version == appInitFileVersion else {
    throw AppInitFileLoadError.unsupportedVersion(initFile.version)
  }

  guard let built = validateAndBuildDetailed(initFile.model, env: env) else {
    throw AppInitFileLoadError.invalidSnapshot
  }

  return ValidatedAppRestore(
    snapshot: initFile.model,
    model: built.model,
    paneSnapshots: built.paneSnapshots
  )
}

// MARK: - Export

func toInitFile(_ model: AppModel, home: String? = nil) -> AppInitFile {
  toInitFile(snapshot: toSnapshot(model, home: home))
}

/// Wrap an already-built snapshot (e.g. a scrollback-grafted one) in the current
/// init-file version. Single source of truth for the written version.
func toInitFile(snapshot: AppModelSnapshot) -> AppInitFile {
  AppInitFile(version: appInitFileVersion, model: snapshot)
}

/// Serialize the model to a snapshot. `home` (the cwd-abbreviation base) defaults
/// to the real ambient home (nil); the three `update()`-internal callers pass
/// `env.homeDirectory()` so the SAVED/SENT payload reproduces, and a test injects a
/// fixed home. The app's checkpoint writers omit it (live ambient).
func toSnapshot(_ model: AppModel, home: String? = nil) -> AppModelSnapshot {
  let h = home ?? CoreEnv.live.homeDirectory()
  let groupSnapshots: [GroupSnapshot] = model.groups.map { group in
    let tabSnapshots: [TabSnapshot] = group.tabs.map { tab in
      let tabTodoSnapshots: [TodoSnapshot]? = tab.todos.isEmpty ? nil : tab.todos.map {
        TodoSnapshot(id: $0.id.rawValue.uuidString, text: $0.text, isDone: $0.isDone)
      }
      var tabSnapshot = TabSnapshot(
        id: tab.id.rawValue.uuidString,
        customTitle: tab.customTitle,
        focusedPaneId: tab.paneTree.focusedPaneId.rawValue.uuidString,
        rootNode: toSplitNodeSnapshot(tab.paneTree.root, home: h),
        color: tab.color
      )
      tabSnapshot.todos = tabTodoSnapshots
      return tabSnapshot
    }
    return GroupSnapshot(
      id: group.id.rawValue.uuidString,
      name: group.name,
      isCollapsed: group.isCollapsed,
      tabs: tabSnapshots
    )
  }

  return AppModelSnapshot(
    groups: groupSnapshots,
    selectedTabId: model.selectedTabId?.rawValue.uuidString
  )
}

/// Build the structural PaneSnapshot embedded in a leaf. Scrollback remains a
/// separate live-engine graft; recovery memo is already model-owned.
private func toPaneSnapshot(_ pane: PaneModel, home: String) -> PaneSnapshot {
  let session = pane.session
  let abbrevCwd = session?.cwd.map { abbreviateHome($0, home: home) }
  let todoSnapshots: [TodoSnapshot]? = pane.todos.isEmpty ? nil : pane.todos.map {
    TodoSnapshot(id: $0.id.rawValue.uuidString, text: $0.text, isDone: $0.isDone)
  }
  var snapshot = PaneSnapshot(
    id: pane.id.rawValue.uuidString,
    title: session?.title ?? "Terminal",
    cwd: abbrevCwd,
    command: pane.session?.lastCommand,
    scrollback: nil,
    theme: pane.theme
  )
  snapshot.todos = todoSnapshots
  snapshot.agentSession = pane.session?.lastAgentSession.map {
    AgentSessionSnapshot(kind: $0.kind, sessionId: $0.sessionId)
  }
  snapshot.fontSizeSteps = pane.fontSizeSteps == 0 ? nil : pane.fontSizeSteps
  snapshot.gridOverride = pane.gridOverride.map {
    PaneGridOverrideSnapshot(columns: $0.columns, rows: $0.rows)
  }
  return snapshot
}

private func toSplitNodeSnapshot(_ node: SplitNodeModel, home: String) -> SplitNodeSnapshot {
  switch node {
  case .leaf(let pane):
    return .leaf(toPaneSnapshot(pane, home: home))
  case .split(let id, let direction, let first, let second, let ratio):
    let dirStr: String
    switch direction {
    case .horizontal: dirStr = "horizontal"
    case .vertical: dirStr = "vertical"
    }
    return .split(
      id: id.rawValue.uuidString,
      direction: dirStr,
      first: toSplitNodeSnapshot(first, home: home),
      second: toSplitNodeSnapshot(second, home: home),
      ratio: Double(ratio)
    )
  }
}

/// Embed scrollback text into a snapshot's tree leaves, keyed by pane id. Pure:
/// the live-session read is the separate impure `scrollbackByPaneId()` step in
/// AppRuntime. Used by both `.exportState` and the enriched checkpoint.
func graftScrollback(onto snapshot: AppModelSnapshot, scrollbackByPaneId: [PaneId: String]) -> AppModelSnapshot {
  AppModelSnapshot(
    groups: snapshot.groups.map { group in
      GroupSnapshot(
        id: group.id,
        name: group.name,
        isCollapsed: group.isCollapsed,
        tabs: group.tabs.map { tab in
          TabSnapshot(
            id: tab.id,
            customTitle: tab.customTitle,
            focusedPaneId: tab.focusedPaneId,
            rootNode: graftScrollbackIntoNode(tab.rootNode, scrollbackByPaneId),
            color: tab.color,
            todos: tab.todos
          )
        }
      )
    },
    selectedTabId: snapshot.selectedTabId
  )
}

private func graftScrollbackIntoNode(_ node: SplitNodeSnapshot, _ scrollbackByPaneId: [PaneId: String]) -> SplitNodeSnapshot {
  switch node {
  case .leaf(var ps):
    if let idStr = ps.id, let uuid = UUID(uuidString: idStr),
       let scrollback = scrollbackByPaneId[PaneId(rawValue: uuid)] {
      ps.scrollback = scrollback
    }
    return .leaf(ps)
  case .split(let id, let direction, let first, let second, let ratio):
    return .split(
      id: id,
      direction: direction,
      first: graftScrollbackIntoNode(first, scrollbackByPaneId),
      second: graftScrollbackIntoNode(second, scrollbackByPaneId),
      ratio: ratio
    )
  }
}

// MARK: - Checkpoint Merge

/// Merge an enriched restore's scrollback into a light restore's pane map.
/// Both inputs are already validated, so this skips re-validation and never
/// tree-walks: it grafts `enriched.paneSnapshots[id].scrollback` into light's
/// [PaneId: PaneSnapshot] map by id. Light is authoritative for structure/model
/// (a pane only in enriched is ignored; a pane only in light keeps nil scrollback).
func mergeCheckpoints(light: ValidatedAppRestore, enriched: ValidatedAppRestore) -> ValidatedAppRestore {
    var mergedPaneSnapshots = light.paneSnapshots
    for (id, scrollback) in enriched.paneSnapshots.compactMapValues(\.scrollback) {
        guard var ps = mergedPaneSnapshots[id] else { continue }
        ps.scrollback = scrollback
        mergedPaneSnapshots[id] = ps
    }
    return ValidatedAppRestore(
        snapshot: light.snapshot,
        model: light.model,
        paneSnapshots: mergedPaneSnapshots
    )
}

// MARK: - Scrollback Truncation

/// How much scrollback a checkpoint keeps per pane, as one value rather than two loose numbers.
/// The bounded history read and the truncation it feeds have to agree -- a read that stops short
/// of what the cut would have kept silently stores less than the pane is owed -- so the call site
/// hands both the same value and the pairing is structural rather than a convention to remember.
struct ScrollbackRetention {
  var maxLines: Int
  var maxChars: Int

  /// The only policy in use: what an enriched checkpoint reads from each pane and stores.
  static let checkpoint = ScrollbackRetention(maxLines: 4000, maxChars: 400_000)
}

/// Truncate scrollback text to the last `keeping.maxLines` lines and `keeping.maxChars`
/// characters. Strips trailing whitespace-only lines. Returns nil for empty/whitespace-only input.
func truncateScrollback(_ text: String, keeping: ScrollbackRetention = .checkpoint) -> String? {
  // Strip trailing whitespace
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  // Keep the last maxLines lines via backward newline scan
  var newlineCount = 0
  var cutIndex: String.Index? = nil
  for i in trimmed.indices.reversed() {
    if trimmed[i] == "\n" {
      newlineCount += 1
      if newlineCount == keeping.maxLines {
        cutIndex = trimmed.index(after: i)
        break
      }
    }
  }
  var result = cutIndex != nil ? String(trimmed[cutIndex!...]) + "\n" : trimmed + "\n"

  // If still over maxChars, take last maxChars breaking at nearest newline
  if result.count > keeping.maxChars {
    let tail = result.suffix(keeping.maxChars)
    if let newlineIdx = tail.firstIndex(of: "\n") {
      result = String(tail[tail.index(after: newlineIdx)...])
    } else {
      result = String(tail)
    }
  }

  return result
}

/// Whether this text would leave anything behind after truncation -- i.e. whether a pane holding
/// it has scrollback worth checkpointing at all. Named for the question the caller is asking, so
/// deciding to checkpoint does not read as assembling a checkpoint payload.
func hasCheckpointableScrollback(_ text: String) -> Bool {
  truncateScrollback(text) != nil
}
