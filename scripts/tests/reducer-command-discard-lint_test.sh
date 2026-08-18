#!/usr/bin/env bash
# Self-test for the gate that rejects a dropped reducer command list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../reducer-command-discard-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- consumed results pass -------------------------------------------------
cat > "$TMP/Consumed.swift" <<'SWIFT'
func run() -> [Command] {
    var commands = update(&model, .createGroup(name: name), env: env)
    commands += update(&model, .beginSidebarRename(target: target), env: env)
    let more = update(
        &model,
        .moveTabs(tabIds: ids, toGroupId: groupId, atIndex: 0),
        env: env)
    hasher.update(&bytes)
    // _ = update(&model, .selectTab(id: id), env: env) -- was a discard
    return commands + more + [.ipcReply(reqId: reqId, result: result)]
}

func tail() -> [Command] {
    return update(&model, .closeTab(id: tabId), env: env)
}
SWIFT
"$LINT" "$TMP/Consumed.swift" >/dev/null \
    || fail "consumed results, a member .update(, and a commented discard should pass"

# --- an explicit discard fails ---------------------------------------------
cat > "$TMP/Discard.swift" <<'SWIFT'
func run() -> [Command] {
    _ = update(&model, .toggleZoomPane(paneId: paneId), env: env)
    return []
}
SWIFT
if "$LINT" "$TMP/Discard.swift" >/dev/null 2>&1; then
    fail "an explicit _ = update() discard should fail"
fi

# --- a bare call fails -----------------------------------------------------
# @discardableResult stays, so this is the shape a developer reaches for and the
# compiler stays silent about. It is the reason this gate exists.
cat > "$TMP/Bare.swift" <<'SWIFT'
func run() -> [Command] {
    update(&model, .clearPaneGridOverride(paneId: paneId), env: env)
    return []
}
SWIFT
if "$LINT" "$TMP/Bare.swift" >/dev/null 2>&1; then
    fail "a bare update() statement should fail"
fi

# --- a bare multi-line call fails ------------------------------------------
cat > "$TMP/BareWrapped.swift" <<'SWIFT'
func run() -> [Command] {
    update(
        &model,
        .setPaneGridOverride(paneId: paneId, grid: grid),
        env: env)
    return []
}
SWIFT
if "$LINT" "$TMP/BareWrapped.swift" >/dev/null 2>&1; then
    fail "a bare update() call wrapped over several lines should fail"
fi

echo "reducer command discard lint self-test passed"
