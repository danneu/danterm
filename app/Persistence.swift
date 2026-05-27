// Model <-> disk: the pure serialization layer plus the thin FileManager I/O around
// it. Restore (decode + validate an init file, restore-command behavior), Export
// (AppModel -> snapshot -> init file, plus scrollback grafting), the recovery
// checkpoint paths (light/enriched/lock URLs and the checkpoint merge), session-lock
// read/write, and scrollback truncation. Everything is pure value-mapping except the
// few `try? FileManager` / `Data(contentsOf:)` calls in the lock and URL helpers,
// kept deliberately thin so the interesting logic stays unit-testable. Split out of
// ModelOperations.swift because snapshot/restore/recovery is a large cohesive concern
// distinct from the live-model helpers; `import Foundation` only -- no AppKit.
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

/// Decode a saved init file and validate that its snapshot can be rebuilt.
func loadValidatedInitFile(from data: Data) throws -> ValidatedAppRestore {
  let initFile: AppInitFile
  do {
    initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
  } catch {
    throw AppInitFileLoadError.decodeFailed
  }

  // Require the current leaf-embedded version. v1 (flat panes array) is rejected
  // outright -- no version-dispatch fork, no one-shot importer. A v1 checkpoint
  // on the first post-upgrade launch falls through to a fresh session.
  guard initFile.version == appInitFileVersion else {
    throw AppInitFileLoadError.unsupportedVersion(initFile.version)
  }

  guard let built = validateAndBuildDetailed(initFile.model) else {
    throw AppInitFileLoadError.invalidSnapshot
  }

  return ValidatedAppRestore(
    snapshot: initFile.model,
    model: built.model,
    paneSnapshots: built.paneSnapshots
  )
}

/// Parse the restore command behavior from CLI arguments.
/// Defaults to `.prefill` to avoid surprising command execution during restore.
func restoreCommandBehavior(from arguments: [String]) -> RestoreCommandBehavior {
  guard let idx = arguments.firstIndex(of: "--restore-commands"),
    idx + 1 < arguments.count
  else {
    return .prefill
  }

  switch arguments[idx + 1] {
  case RestoreCommandBehavior.execute.rawValue:
    return .execute
  case RestoreCommandBehavior.prefill.rawValue:
    return .prefill
  default:
    return .prefill
  }
}

/// Convert saved command metadata into live shell input for restore.
/// `.prefill` restores the draft command without executing it.
func restoreInitialInput(for command: String?, behavior: RestoreCommandBehavior) -> String? {
  guard let command, !command.isEmpty else { return nil }
  switch behavior {
  case .prefill:
    return command
  case .execute:
    return command.hasSuffix("\n") ? command : command + "\n"
  }
}

// MARK: - Export

func toInitFile(_ model: AppModel) -> AppInitFile {
  toInitFile(snapshot: toSnapshot(model))
}

/// Wrap an already-built snapshot (e.g. a scrollback-grafted one) in the current
/// init-file version. Single source of truth for the written version.
func toInitFile(snapshot: AppModelSnapshot) -> AppInitFile {
  AppInitFile(version: appInitFileVersion, model: snapshot)
}

func toSnapshot(_ model: AppModel) -> AppModelSnapshot {
  let groupSnapshots: [GroupSnapshot] = model.groups.map { group in
    let tabSnapshots: [TabSnapshot] = group.tabs.map { tab in
      let tabTodoSnapshots: [TodoSnapshot]? = tab.todos.isEmpty ? nil : tab.todos.map {
        TodoSnapshot(id: $0.id.uuidString, text: $0.text, isDone: $0.isDone)
      }
      var tabSnapshot = TabSnapshot(
        id: tab.id.rawValue.uuidString,
        customTitle: tab.customTitle,
        focusedPaneId: tab.focusedPaneId.rawValue.uuidString,
        rootNode: toSplitNodeSnapshot(tab.rootNode),
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

/// Build the PaneSnapshot embedded in a leaf, reading the leaf's PaneModel
/// directly. Always emits `scrollback: nil`; scrollback is grafted separately
/// (graftScrollback) from a live-surface read so this stays pure.
private func toPaneSnapshot(_ pane: PaneModel) -> PaneSnapshot {
  let abbrevCwd = pane.cwd.map { abbreviateHome($0) }
  let launch: PaneLaunchSnapshot?
  if pane.lastCommand != nil || abbrevCwd != nil {
    launch = PaneLaunchSnapshot(command: pane.lastCommand, cwd: abbrevCwd)
  } else {
    launch = nil
  }
  let todoSnapshots: [TodoSnapshot]? = pane.todos.isEmpty ? nil : pane.todos.map {
    TodoSnapshot(id: $0.id.uuidString, text: $0.text, isDone: $0.isDone)
  }
  var snapshot = PaneSnapshot(
    id: pane.id.rawValue.uuidString,
    title: pane.title,
    cwd: abbrevCwd,
    launch: launch,
    scrollback: nil,
    theme: pane.theme
  )
  snapshot.todos = todoSnapshots
  return snapshot
}

private func toSplitNodeSnapshot(_ node: SplitNodeModel) -> SplitNodeSnapshot {
  switch node {
  case .leaf(let pane):
    return .leaf(toPaneSnapshot(pane))
  case .split(let id, let direction, let first, let second, let ratio):
    let dirStr: String
    switch direction {
    case .horizontal: dirStr = "horizontal"
    case .vertical: dirStr = "vertical"
    }
    return .split(
      id: id.rawValue.uuidString,
      direction: dirStr,
      first: toSplitNodeSnapshot(first),
      second: toSplitNodeSnapshot(second),
      ratio: Double(ratio)
    )
  }
}

/// Embed scrollback text into a snapshot's tree leaves, keyed by pane id. Pure:
/// the live-surface read is the separate impure `scrollbackByPaneId()` step in
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

// MARK: - Recovery Paths
//
// Session persistence lives in
// ~/Library/Application Support/<bundle-id>/Recovery/:
//   last-light.json    — frequent structural checkpoint (no scrollback, 2s debounce)
//   last-enriched.json — periodic full checkpoint (structure + scrollback, 60s timer)
//   session.json       — lock file, written at launch and deleted on clean exit
//
// Namespacing by bundle ID isolates DanTerm.app (com.danneu.danterm) from
// DanTerm Dev.app (com.danneu.danterm-dev) so the dev build never restores
// from a prod session and vice versa. The bundleId parameter exists for
// tests; production code always takes the default.

func recoveryDirectoryURL(
    bundleId: String = Bundle.main.bundleIdentifier ?? "com.danneu.danterm"
) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleId, isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
}

func lightCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-light.json")
}

func enrichedCheckpointURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("last-enriched.json")
}

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

func sessionLockURL() -> URL {
    recoveryDirectoryURL().appendingPathComponent("session.json")
}

// MARK: - Session Lock I/O
//
// All session lock serialization goes through these three helpers so the
// JSON encoder/decoder date strategy (.iso8601) is configured in one place.

/// Write a session lock file at launch. Its presence at next launch means the
/// previous exit was unclean — no PID liveness check needed.
func writeSessionLockFile() {
    let lock = SessionLock(pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(lock) else { return }
    let dir = recoveryDirectoryURL()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: sessionLockURL(), options: .atomic)
}

/// Read the session lock if it exists (non-nil = previous exit was unclean).
func readSessionLockFile() -> SessionLock? {
    guard let data = try? Data(contentsOf: sessionLockURL()) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SessionLock.self, from: data)
}

/// Delete the session lock on clean termination.
func deleteSessionLockFile() {
    try? FileManager.default.removeItem(at: sessionLockURL())
}

// MARK: - Scrollback Truncation

/// Truncate scrollback text to the last `maxLines` lines and `maxChars` characters.
/// Strips trailing whitespace-only lines. Returns nil for empty/whitespace-only input.
func truncateScrollback(_ text: String, maxLines: Int = 4000, maxChars: Int = 400_000) -> String? {
  // Strip trailing whitespace
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  // Keep the last maxLines lines via backward newline scan
  var newlineCount = 0
  var cutIndex: String.Index? = nil
  for i in trimmed.indices.reversed() {
    if trimmed[i] == "\n" {
      newlineCount += 1
      if newlineCount == maxLines {
        cutIndex = trimmed.index(after: i)
        break
      }
    }
  }
  var result = cutIndex != nil ? String(trimmed[cutIndex!...]) + "\n" : trimmed + "\n"

  // If still over maxChars, take last maxChars breaking at nearest newline
  if result.count > maxChars {
    let tail = result.suffix(maxChars)
    if let newlineIdx = tail.firstIndex(of: "\n") {
      result = String(tail[tail.index(after: newlineIdx)...])
    } else {
      result = String(tail)
    }
  }

  return result
}
