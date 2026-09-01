// Model <-> disk: the pure serialization/restore policy, no file I/O. Restore
// (decode + validate an init file from in-memory Data),
// Export (AppModel -> snapshot -> init file, plus scrollback grafting), the
// scrollback sidecar's own codec and its graft onto a validated session, and
// checkpoint scrollback policy and normalization. Everything is pure value-mapping: the FileManager/Data
// recovery-path and session-lock I/O that used to tail this file now lives in
// DanTermSupport's RecoveryStore -- the codec stays here, the disk touch moved out.
// Split out of ModelOperations.swift because snapshot/restore/recovery is a large
// cohesive concern distinct from the live-model helpers; `import Foundation` only --
// no AppKit.
import Foundation

// MARK: - Restore

struct ValidatedAppRestore {
  let model: AppModel
  let paneSnapshots: [PaneId: PaneSnapshot]
}

enum AppInitFileLoadError: Error, Equatable {
  case decodeFailed(String)
  case unsupportedVersion(Int)
  case invalidSnapshot

  /// States the shared failure detail that each restore surface frames for its context.
  var reason: String {
    switch self {
    case .decodeFailed(let description):
      return "The file is not valid DanTerm JSON: \(description)"
    case .unsupportedVersion(let version):
      return "Unsupported state file version: \(version)."
    case .invalidSnapshot:
      return "The state file failed snapshot validation."
    }
  }
}

/// Decode a saved init file and validate that its snapshot can be rebuilt. Takes
/// `env` (defaulting to `.live`) so id-less entries mint reproducible ids and
/// `~`-cwds expand against an injectable home; app restore omits it (live ambient).
func loadValidatedInitFile(from data: Data, env: CoreEnv = .live) throws -> ValidatedAppRestore {
  let initFile: AppInitFile
  do {
    initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
  } catch {
    throw AppInitFileLoadError.decodeFailed(String(describing: error))
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
        TodoSnapshot(id: $0.id, text: $0.text, isDone: $0.isDone)
      }
      var tabSnapshot = TabSnapshot(
        id: tab.id,
        customTitle: tab.customTitle,
        focusedPaneId: tab.paneTree.focusedPaneId,
        rootNode: toSplitNodeSnapshot(tab.paneTree.root, home: h),
        color: tab.color
      )
      tabSnapshot.todos = tabTodoSnapshots
      return tabSnapshot
    }
    return GroupSnapshot(
      id: group.id,
      name: group.name,
      isCollapsed: group.isCollapsed,
      tabs: tabSnapshots
    )
  }

  return AppModelSnapshot(
    groups: groupSnapshots,
    selectedTabId: model.selectedTabId,
    sidebar: SidebarSnapshot(
      isCollapsed: model.sidebar.isCollapsed,
      width: Double(model.sidebar.width)
    )
  )
}

/// Build the structural PaneSnapshot embedded in a leaf. Scrollback remains a
/// separate live-engine graft; recovery memo is already model-owned.
private func toPaneSnapshot(_ pane: PaneModel, home: String) -> PaneSnapshot {
  let session = pane.session
  let abbrevCwd = session?.cwd.map { abbreviateHome($0, home: home) }
  let todoSnapshots: [TodoSnapshot]? = pane.todos.isEmpty ? nil : pane.todos.map {
    TodoSnapshot(id: $0.id, text: $0.text, isDone: $0.isDone)
  }
  var snapshot = PaneSnapshot(
    id: pane.id,
    title: session?.titleState.claimed,
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
    return .split(
      id: id,
      direction: direction,
      first: toSplitNodeSnapshot(first, home: home),
      second: toSplitNodeSnapshot(second, home: home),
      ratio: Double(ratio.value)
    )
  }
}

/// Embed scrollback text into a snapshot's tree leaves, keyed by pane id. Pure:
/// the live-session read is the separate impure `scrollbackByPaneId()` step in
/// AppRuntime. Export and both checkpoint tiers use this shared transform.
func graftScrollback(onto snapshot: AppModelSnapshot, scrollbackByPaneId: [PaneId: String]) -> AppModelSnapshot {
  snapshot.mapPaneSnapshots { pane in
    guard let paneId = pane.id,
          let scrollback = scrollbackByPaneId[paneId] else {
      return pane
    }
    var pane = pane
    pane.scrollback = scrollback
    return pane
  }
}

// MARK: - Scrollback Sidecar

/// The scrollback sidecar's format version, versioned apart from the init file because the
/// two files hold unrelated shapes and change for unrelated reasons.
let scrollbackSidecarVersion = 1

/// The sidecar's disk shape: normalized pane text keyed by the pane's UUID string. The keys
/// are strings rather than `PaneId` because `TypedId` is not `CodingKeyRepresentable`, and a
/// protocol-wide conformance would reshape every other id-keyed encoding in the tree.
private struct ScrollbackSidecarFile: Codable {
  var version: Int
  var scrollback: [String: String]
}

/// Serialize the sidecar the scrollback checkpoint writes. It carries no structure at all:
/// the session file is the only structure on disk, and a sidecar alone restores nothing.
func encodeScrollbackSidecar(_ scrollbackByPaneId: [PaneId: String]) throws -> Data {
  var byKey: [String: String] = [:]
  byKey.reserveCapacity(scrollbackByPaneId.count)
  for (paneId, text) in scrollbackByPaneId {
    byKey[paneId.rawValue.uuidString] = text
  }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(
    ScrollbackSidecarFile(version: scrollbackSidecarVersion, scrollback: byKey)
  )
}

/// Decode a sidecar, or report nil for one the loader must treat exactly as an absent file:
/// bytes that do not decode, and a file from another sidecar version. An entry whose key is
/// not a UUID is dropped rather than failing the whole file -- the graft is defensive by id
/// anyway, so one unreadable key must not cost the other panes their text.
func loadScrollbackSidecar(from data: Data) -> [PaneId: String]? {
  guard let file = try? JSONDecoder().decode(ScrollbackSidecarFile.self, from: data),
        file.version == scrollbackSidecarVersion else {
    return nil
  }
  var result: [PaneId: String] = [:]
  result.reserveCapacity(file.scrollback.count)
  for (key, text) in file.scrollback {
    guard let uuid = UUID(uuidString: key) else { continue }
    result[PaneId(rawValue: uuid)] = text
  }
  return result
}

/// Graft sidecar text onto an already validated session restore, by pane id. The session
/// owns structure outright: an entry for a pane the session does not hold is ignored, and a
/// pane the sidecar does not mention keeps nil scrollback. That is what lets a deliberately
/// stale sidecar -- the one an empty-model quit preserves -- graft harmlessly.
func graftSidecar(
  onto restore: ValidatedAppRestore,
  scrollbackByPaneId: [PaneId: String]
) -> ValidatedAppRestore {
  var paneSnapshots = restore.paneSnapshots
  for (id, scrollback) in scrollbackByPaneId {
    guard var pane = paneSnapshots[id] else { continue }
    pane.scrollback = scrollback
    paneSnapshots[id] = pane
  }
  return ValidatedAppRestore(model: restore.model, paneSnapshots: paneSnapshots)
}

// MARK: - Checkpoint Scrollback

/// How much normalized scrollback a checkpoint stores per pane.
struct ScrollbackRetention {
  var maxLines: Int
  var maxChars: Int

  /// The only policy in use: what the scrollback checkpoint reads from each pane and stores.
  static let checkpoint = ScrollbackRetention(maxLines: 4000, maxChars: 400_000)

  /// Reserves the stored final newline before the engine applies the one positional cut.
  var primaryHistoryLimits: PrimaryHistoryLimits {
    PrimaryHistoryLimits(maxLines: maxLines, maxChars: max(0, maxChars - 1))
  }
}

/// Plain engine limits derived from persistence policy without exposing that policy downstream.
struct PrimaryHistoryLimits: Equatable {
  var maxLines: Int
  var maxChars: Int
}

/// Normalizes an already bounded engine tail for storage, without applying either budget again.
func normalizeCheckpointScrollback(_ text: String) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return trimmed + "\n"
}
