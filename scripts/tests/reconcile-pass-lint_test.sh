#!/usr/bin/env bash
# Self-test for the reconcile-pass no-send gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../reconcile-pass-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- whole-file rule -------------------------------------------------------
cat > "$TMP/Sweep.swift" <<'SWIFT'
func reconcile() -> [Msg] {
    return reconcileSidebar(tally: tally)
}
// A comment mentioning runtime?.send(.sidebarRenameEnded) is not a call.
SWIFT
"$LINT" --whole "$TMP/Sweep.swift" >/dev/null || fail "a returning sweep should pass"

cat > "$TMP/Sweep.swift" <<'SWIFT'
func reconcile() {
    runtime?.send(.sidebarRenameEnded)
}
SWIFT
if "$LINT" --whole "$TMP/Sweep.swift" >/dev/null 2>&1; then
    fail "a send() in the sweep file should fail"
fi

# --- whole-file window rule ------------------------------------------------
cat > "$TMP/Sweep.swift" <<'SWIFT'
func reconcileThemeBrowser() {
    let browser = ThemeBrowserView()
    contentArea.addSubview(browser)
    browser.apply(projection)
}
func reconcileDialog() {
    surface.apply(projection)
    surface.raise()
}
// A comment about noticePanel?.makeKeyAndOrderFront(nil) is not a call.
SWIFT
"$LINT" --whole "$TMP/Sweep.swift" >/dev/null \
    || fail "building a subview in a handed host, and driving a surface, should pass"

cat > "$TMP/Sweep.swift" <<'SWIFT'
func reconcileNotice() {
    noticePanel = NoticePanel(runtime: self)
}
SWIFT
if "$LINT" --whole "$TMP/Sweep.swift" >/dev/null 2>&1; then
    fail "constructing a panel in the sweep file should fail"
fi

cat > "$TMP/Sweep.swift" <<'SWIFT'
func reconcileNotice() {
    surface.panel.makeKeyAndOrderFront(nil)
}
SWIFT
if "$LINT" --whole "$TMP/Sweep.swift" >/dev/null 2>&1; then
    fail "ordering a window in the sweep file should fail"
fi

# --- marked-region rule ----------------------------------------------------
region_file() {
    cat > "$TMP/View.swift" <<SWIFT
func handleClick() {
    runtime?.send(.selectTab(id: id))
}

// reconcile-pass-lint: no-send begin
func applySidebarOps() -> [Msg] {
$1
}
// reconcile-pass-lint: no-send end

func afterTheFence() {
    runtime?.send(.sidebarRenameEnded)
}
SWIFT
}

region_file '    return endActiveRename(target)'
"$LINT" --region "$TMP/View.swift" >/dev/null \
    || fail "a reporting region should pass while sends outside it are fine"

region_file '    sendNow(finishActiveRename())
    session.sendText("x")'
"$LINT" --region "$TMP/View.swift" >/dev/null \
    || fail "sendNow(/sendText( must not read as a send( call"

region_file '    runtime?.send(.sidebarRenameEnded)'
if "$LINT" --region "$TMP/View.swift" >/dev/null 2>&1; then
    fail "a send() inside the region should fail"
fi

region_file '    // runtime?.send(.sidebarRenameEnded) -- rejected, see RI1'
"$LINT" --region "$TMP/View.swift" >/dev/null \
    || fail "a commented-out send inside the region should pass"

# Deleting the fence must not be a way to pass.
cat > "$TMP/View.swift" <<'SWIFT'
func applySidebarOps() {
    runtime?.send(.sidebarRenameEnded)
}
SWIFT
if "$LINT" --region "$TMP/View.swift" >/dev/null 2>&1; then
    fail "a region file with no markers should fail"
fi

cat > "$TMP/View.swift" <<'SWIFT'
// reconcile-pass-lint: no-send begin
func applySidebarOps() -> [Msg] { [] }
// reconcile-pass-lint: no-send end
// reconcile-pass-lint: no-send begin
func second() { runtime?.send(.sidebarRenameEnded) }
// reconcile-pass-lint: no-send end
SWIFT
if "$LINT" --region "$TMP/View.swift" >/dev/null 2>&1; then
    fail "a duplicated fence should fail"
fi

echo "reconcile pass lint self-test passed"
