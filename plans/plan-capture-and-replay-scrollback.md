# Scrollback Buffer Capture & Replay

## Context

DanTerm can export/import its state as JSON (`--init <path>`), capturing tab groups, tabs, split layout, cwd, and last command per pane. On restore, surfaces are recreated with saved cwd/command but **terminal scrollback is lost**. This adds scrollback capture on export and replay on restore, following cmux's proven shell-driven replay approach.

## Approach

**Capture**: On export, read each surface's scrollback via `ghostty_surface_read_text` (plain text, no ANSI codes). Store in the snapshot JSON as an optional `scrollback` field per pane.

**Replay**: On restore, write each pane's scrollback to a temp file, pass `DANTERM_RESTORE_SCROLLBACK_FILE=<path>` as an env var to the surface. A shell integration hook `cat`s the file on startup. AppRuntime owns replay file lifecycle and cleans up on pane teardown (the shell hook also deletes as a fast path, but the app doesn't rely on it).

### Key Design Decisions

1. Scrollback capture is impure (requires live surface access), but `update()` must remain pure. Solution: `update(.exportState)` produces the pure `AppModelSnapshot` as before. `AppRuntime.perform(.exportState(...))` enriches each pane with scrollback read from surfaces before encoding JSON.

2. Replay file lifecycle is owned by AppRuntime, not by the shell hook alone. AppRuntime tracks replay file URLs per pane and deletes them on surface destruction / surface close / app teardown. The shell hook also deletes as a convenience, but orphan files are cleaned up by the app regardless.

3. All impure replay file I/O lives in AppRuntime (not ModelOperations) to preserve the Elm-style purity boundary. Only `truncateScrollback()` (a pure function) goes in ModelOperations.

## Files to Modify

| File | Change |
|------|--------|
| `app/Model.swift` | Add `scrollback: String?` to `PaneSnapshot` |
| `app/ModelOperations.swift` | Update `PaneSnapshot` construction sites (`scrollback: nil`), add `truncateScrollback()` pure utility |
| `app/Effect.swift` | Change `.exportState(AppInitFile)` → `.exportState(AppModelSnapshot)` |
| `app/Update.swift` | Return `toSnapshot(model)` instead of `toInitFile(model)` |
| `app/AppRuntime.swift` | Add `readScrollbackText(surface:)`, enrich snapshot in export handler, replay file write/cleanup, pass replay env var in `bootstrapFromSnapshot()` |
| `app/TerminalView.swift` | No changes needed (already supports arbitrary env vars) |
| `README.md` | Add scrollback restore snippets to shell integration docs |
| `tests/SnapshotTests.swift` | Backward compat tests for `scrollback` field |
| `tests/ExportTests.swift` | `truncateScrollback()` tests, updated export assertions |

## Implementation Steps

### 1. Add `scrollback` to `PaneSnapshot` (`Model.swift:168-173`)

```swift
struct PaneSnapshot: Codable {
    let id: String?
    let title: String?
    let cwd: String?
    let launch: PaneLaunchSnapshot?
    let scrollback: String?  // NEW — optional for backward compat
}
```

### 2. Update `PaneSnapshot` construction (`ModelOperations.swift:421-426`)

Add `scrollback: nil` to the `PaneSnapshot(...)` call in `toSnapshot()`. This keeps the pure function unchanged — scrollback enrichment happens later in the runtime.

### 3. Add `truncateScrollback()` (`ModelOperations.swift`)

Pure, testable utility:

```swift
func truncateScrollback(_ text: String, maxLines: Int = 4000, maxChars: Int = 400_000) -> String?
```

- Returns `nil` for empty/whitespace-only input
- Takes the **last** `maxLines` lines (most recent output)
- If still over `maxChars`, takes the last `maxChars` characters, breaking at nearest newline

### 4. Change export Effect (`Effect.swift`, `Update.swift`)

**Effect.swift**: `.exportState(AppModelSnapshot)` (was `AppInitFile`)

**Update.swift**: `.exportState` handler returns `[.exportState(toSnapshot(model))]`

### 5. Enrich snapshot with scrollback in runtime (`AppRuntime.swift:124-154`)

In `perform(.exportState(snapshot))`:
1. Build enriched pane snapshots by iterating `snapshot.panes`
2. For each pane, look up the surface via `surfaces[paneId]`
3. Call `readScrollbackText(surface:)` → `truncateScrollback()`
4. Construct new `PaneSnapshot` with `scrollback` field populated
5. Build `AppInitFile(version: 1, model: enrichedSnapshot)`
6. JSON encode, show save panel, write (same as current)

### 6. Add `readScrollbackText()` (`AppRuntime.swift`)

Reads full scrollback from a ghostty surface using the C API. Uses `rectangle: false` (line-based selection) matching Ghostty's own `SurfaceView_AppKit.swift:221` pattern:

```swift
private func readScrollbackText(surface: ghostty_surface_t) -> String? {
    let topLeft = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
    let bottomRight = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
    let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let ptr = text.text, text.text_len > 0 else { return nil }
    return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(text.text_len)), encoding: .utf8)
}
```

### 7. Replay file management in AppRuntime (`AppRuntime.swift`)

AppRuntime owns replay file lifecycle end-to-end:

**State**: Add `private var replayFiles: [PaneId: URL] = [:]` to track written replay files.

**Write** (in `bootstrapFromSnapshot`): For each pane with scrollback, write to `$TMPDIR/danterm-scrollback/<UUID>.txt`, store URL in `replayFiles[paneId]`, pass env var to surface.

**Cleanup**: Centralized `cleanupReplayFile(for:)` helper called from every teardown path: `.destroySurface`, `.surfaceCreationFailed`, and app shutdown. Stale files from prior sessions cleaned unconditionally on app launch.

```swift
// Private state:
private var replayFiles: [PaneId: URL] = [:]
private static let replayDirectoryName = "danterm-scrollback"
```

**Create helper**:
```swift
private func writeReplayFile(scrollback: String) -> URL? {
    guard let data = scrollback.data(using: .utf8) else { return nil }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
    guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
    return fileURL
}
```

**Delete helper** (single point of deletion, called from every teardown path):
```swift
private func cleanupReplayFile(for paneId: PaneId) {
    if let url = replayFiles.removeValue(forKey: paneId) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

**Call sites for `cleanupReplayFile(for:)`**:
1. `perform(.destroySurface(paneId))` — normal pane close
2. Directly in `bootstrapFromSnapshot` when `view.surface == nil` — surface creation failed after replay file was written (note: `.surfaceCreationFailed` msg does NOT emit `.destroySurface`, so cleanup must happen explicitly here)
3. App shutdown (e.g. `applicationWillTerminate` or terminate effect) — iterate all remaining `replayFiles` keys

**In `bootstrapFromSnapshot`, when creating surfaces**:
```swift
var envVars: [(String, String)] = [("DANTERM_TOKEN", token)]
if let scrollback = ps?.scrollback {
    if let replayURL = writeReplayFile(scrollback: scrollback) {
        replayFiles[paneId] = replayURL
        envVars.append(("DANTERM_RESTORE_SCROLLBACK_FILE", replayURL.path))
    }
}
let view = TerminalView(ghosttyApp: ghosttyApp, workingDirectory: resolved?.cwd,
                         command: resolved?.command, envVars: envVars)
if view.surface == nil {
    cleanupReplayFile(for: paneId)  // Clean up before the file becomes unreachable
    send(.surfaceCreationFailed(paneId: paneId))
    return
}
```

**Stale file cleanup** (unconditional on every app launch, in `AppDelegate.applicationDidFinishLaunching`, before `bootstrapFromSnapshot` or `createTab`):
```swift
/// Delete all files in $TMPDIR/danterm-scrollback/ from prior sessions.
func cleanupStaleReplayDirectory() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
}
```

This runs unconditionally regardless of whether `--init` is used, ensuring stale files from any prior session are always cleaned up.

### 8. Shell integration docs (`README.md`)

Add scrollback restore snippets. These are **independent** of the `DANTERM_TOKEN` guard — scrollback replay should work even without command tracking.

**Zsh** (before the DANTERM_TOKEN block):
```zsh
# Restore scrollback from previous DanTerm session
if [[ -n "$DANTERM_RESTORE_SCROLLBACK_FILE" ]]; then
  _danterm_sbf="$DANTERM_RESTORE_SCROLLBACK_FILE"
  unset DANTERM_RESTORE_SCROLLBACK_FILE
  if [[ -r "$_danterm_sbf" ]]; then
    /bin/cat -- "$_danterm_sbf" 2>/dev/null || true
    /bin/rm -f -- "$_danterm_sbf" >/dev/null 2>&1 || true
  fi
  unset _danterm_sbf
fi
```

**Fish** (before the DANTERM_TOKEN block):
```fish
# Restore scrollback from previous DanTerm session
if set -q DANTERM_RESTORE_SCROLLBACK_FILE
  set -l f $DANTERM_RESTORE_SCROLLBACK_FILE
  set -e DANTERM_RESTORE_SCROLLBACK_FILE
  if test -r "$f"
    /bin/cat -- "$f" 2>/dev/null; or true
    /bin/rm -f -- "$f" >/dev/null 2>&1; or true
  end
end
```

### 9. Tests

**SnapshotTests.swift** — backward compatibility:
- Decode JSON without `scrollback` field → `nil`
- Decode JSON with `scrollback` field → preserved
- Round-trip encode/decode with scrollback

**ExportTests.swift** — truncation:
- `truncateScrollback("")` → `nil`
- `truncateScrollback("  \n  ")` → `nil`
- Text under limits → returned as-is
- 5000-line text → last 4000 lines kept
- Text over 400K chars → last 400K chars, broken at newline
- Update existing export effect assertions for new `AppModelSnapshot` payload

**Replay cleanup** (ExportTests.swift or new ScrollbackTests.swift):
- Verify replay file is deleted on `.destroySurface` (conceptual — actual I/O is in runtime, but we can test the cleanup logic tracks correctly)

## Verification

1. `just test` — all existing + new tests pass
2. `just build` — app compiles
3. Manual: Export State → inspect JSON, verify `scrollback` field on panes with output
4. Manual: `--init` with scrollback-containing JSON → verify scrollback appears in terminal after shell starts (requires shell integration snippet installed)
