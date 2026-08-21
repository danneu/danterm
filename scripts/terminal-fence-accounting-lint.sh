#!/usr/bin/env bash
# Pins every production owner-queue fence to the host and controller accounting choke points.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"

ROOT="${1:-$SCRIPT_DIR/..}"
HOST="$ROOT/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
CONTROLLER="$ROOT/lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift"
SOURCES="$ROOT/lib/TerminalPTY/Sources"
CALLER_ROOTS=("$SOURCES")
if [[ -d "$ROOT/app" ]]; then
    CALLER_ROOTS+=("$ROOT/app")
fi

# For a source file this lint cannot read. The rule's rationale would only mislead
# here: nothing was checked, so nothing was violated.
setup_fail() {
    echo "terminal-fence-accounting-lint: $1" >&2
    echo "  this lint checked nothing. Point it at the moved file or update the path here." >&2
    exit 1
}

fail() {
    echo "terminal-fence-accounting-lint: $1" >&2
    lint_rationale <<'EOF'
terminal-fence-accounting lint FAILED: the production owner-queue fence
no longer runs through its two accounting choke points.

Every synchronous fence a pane takes on the host's owner queue is
counted, and the controller's own total has to equal the host's
independent census. That equality is the only thing that can prove no
fence escaped: a second entry point, or a counted path that stops being
counted, makes the two numbers disagree for a reason no test can name.
So the shape is pinned rather than the behavior -- one counted path in
the host, one performProductionFence call in the controller, and that
call inside performAccountedFence where the timing is charged.

If you need a new fence, route it through performAccountedFence and give
it an operation value that carries its payload type. Do not add a second
call site, and do not reach past the choke point for one of the host's
fencedSnapshot / fencedFrameState / beginCloseAndSnapshot entry points --
those are the bypass this lint exists to catch.
EOF
    exit 1
}

[[ -f "$HOST" ]] || setup_fail "missing host source: $HOST"
[[ -f "$CONTROLLER" ]] || setup_fail "missing controller source: $CONTROLLER"

sync_count="$(rg -c '^[[:space:]]*queue\.sync[[:space:]]*\{' "$HOST" || true)"
[[ "$sync_count" == "1" ]] \
    || fail "expected one host queue.sync primitive, found $sync_count"

production_count="$(rg -c 'countsAsProduction:[[:space:]]*true' "$HOST" || true)"
[[ "$production_count" == "1" ]] \
    || fail "expected one counted host production-fence path, found $production_count"

legacy_pattern='host\.(fencedSnapshot|fencedFrameState|fencedConsumptionState|fencedDiagnosticState|beginCloseAndSnapshot|setUpdateHandler)\('
if rg --glob '!TerminalPTYHost.swift' -n "$legacy_pattern" "${CALLER_ROOTS[@]}"; then
    fail "production source bypasses performProductionFence"
fi

all_call_matches="$(
    rg --glob '!TerminalPTYHost.swift' -n '\.performProductionFence\(' \
        "${CALLER_ROOTS[@]}" || true
)"
all_call_count="$(printf '%s\n' "$all_call_matches" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$all_call_count" == "1" ]] \
    || fail "expected one package production-fence call, found $all_call_count"

call_matches="$(rg -n 'host\.performProductionFence\(' "$CONTROLLER" || true)"
call_count="$(printf '%s\n' "$call_matches" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$call_count" == "1" ]] \
    || fail "expected one controller production-fence call, found $call_count"

accounted_start="$(
    rg -n '^[[:space:]]*private static func performAccountedFence[<(]' "$CONTROLLER" \
        | cut -d: -f1
)"
[[ -n "$accounted_start" ]] || fail "missing controller accounted-fence choke point"

accounted_end="$(
    awk -v start="$accounted_start" '
        NR > start && /^[[:space:]]*(private|package|public|internal) (static )?func / {
            print NR
            exit
        }
    ' "$CONTROLLER"
)"
if [[ -z "$accounted_end" ]]; then
    accounted_end="$(($(wc -l < "$CONTROLLER") + 1))"
fi

call_line="$(printf '%s\n' "$call_matches" | cut -d: -f1)"
if ((call_line <= accounted_start || call_line >= accounted_end)); then
    fail "controller production-fence call is outside performAccountedFence"
fi

echo "terminal fence accounting lint passed"
