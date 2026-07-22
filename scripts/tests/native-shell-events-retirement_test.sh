#!/usr/bin/env bash
# Behavioral retirement gate for the native shell-event rollout: shipped assets,
# user-facing setup, and active protocol plans must not revive the title shim.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

fail() {
    echo "native-shell-events-retirement_test: $*" >&2
    exit 1
}

legacy_pattern='__DANTERM_EVT__|legacyPrivateShell|DantermEvent|parseDantermEvent|translateMsg|PaneTokenStore'

if rg -n "$legacy_pattern" \
    "$repo_root/app" \
    "$repo_root/lib/TerminalCore/Sources" \
    "$repo_root/lib/TerminalPTY/Sources" \
    "$repo_root/integrations/shell-integration" \
    "$repo_root/README.md" \
    "$repo_root/plan-terminal-engine/10-protocols-shell-integration.md" \
    "$repo_root/plan-terminal-engine/14-roadmap.md" \
    "$repo_root/plan-terminal-engine/15-open-questions.md"; then
    fail "legacy title-channel shell event references remain in active surfaces"
fi

for shell in zsh bash fish; do
    asset="$repo_root/integrations/shell-integration/danterm.$shell"
    [[ -r "$asset" ]] || fail "missing canonical $shell integration"
    rg -qF 'DanTermShell=1' "$asset" \
        || fail "$shell integration does not emit the native protocol"
done

echo "native shell-event retirement tests passed"
