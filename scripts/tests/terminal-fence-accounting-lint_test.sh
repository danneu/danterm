#!/usr/bin/env bash
# Self-test for the terminal owner-queue fence accounting architecture gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-fence-accounting-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed/lib/TerminalPTY/Sources/TerminalPTYHost"
mkdir -p "$TMP/allowed/lib/TerminalPTY/Sources/TerminalPaneSession"
cat > "$TMP/allowed/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift" <<'EOF'
actor TerminalPTYHost {
    nonisolated private func fence() {
        queue.sync {}
    }

    package nonisolated func performProductionFence() {
        fence(countsAsProduction: true)
    }
}
EOF
cat > "$TMP/allowed/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift" <<'EOF'
final class TerminalPaneSessionController {
    private static func performAccountedFence() {
        host.performProductionFence()
    }
}
EOF
"$LINT" "$TMP/allowed" >/dev/null || fail "single accounted fence path should pass"

cp -R "$TMP/allowed" "$TMP/second-sync"
printf '\nfunc bypass() {\n    queue.sync {}\n}\n' \
    >> "$TMP/second-sync/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
if "$LINT" "$TMP/second-sync" >/dev/null 2>&1; then
    fail "a second host queue.sync should fail"
fi

cp -R "$TMP/allowed" "$TMP/controller-bypass"
printf '\nfunc bypass() { host.performProductionFence() }\n' \
    >> "$TMP/controller-bypass/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift"
if "$LINT" "$TMP/controller-bypass" >/dev/null 2>&1; then
    fail "a second controller production-fence entry should fail"
fi

# A rule violation has to explain the rule. "expected one, found two" alone reads as
# an arbitrary count, and the cheapest way to satisfy it is to delete the wrong call.
message="$("$LINT" "$TMP/second-sync" 2>&1 || true)"
for expected in "accounting choke points" "performAccountedFence"; do
    case "$message" in
        *"$expected"*) ;;
        *) fail "the violation message should explain '$expected': $message" ;;
    esac
done

echo "terminal fence accounting lint self-test passed"
