#!/usr/bin/env bash
# Self-test for the AGENTS.md length budget.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../agents-md-budget-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

write_agents_md() { # root, line count
    mkdir -p "$1"
    : > "$1/AGENTS.md"
    for (( i = 0; i < $2; i++ )); do echo "line $i" >> "$1/AGENTS.md"; done
}

write_agents_md "$TMP/under" 250
AGENTS_MD_BUDGET_LINT_ROOT="$TMP/under" "$LINT" >/dev/null \
    || fail "a file exactly at the budget should pass"

write_agents_md "$TMP/over" 251
AGENTS_MD_BUDGET_LINT_ROOT="$TMP/over" "$LINT" >/dev/null 2>&1 \
    && fail "a file one line over the budget should fail"

# The failure has to say why the cap exists and where the detail should go, not just
# report a number: an agent that trips this gate reads the message and nothing else.
message="$(AGENTS_MD_BUDGET_LINT_ROOT="$TMP/over" "$LINT" 2>&1 || true)"
for expected in "251 lines" "less likely to be followed" "agent-docs/"; do
    case "$message" in
        *"$expected"*) ;;
        *) fail "the over-budget message should explain '$expected': $message" ;;
    esac
done

# A missing file is a failure, not a pass. A gate that reports success over nothing at
# all is worse than no gate.
AGENTS_MD_BUDGET_LINT_ROOT="$TMP/empty" "$LINT" >/dev/null 2>&1 \
    && fail "a missing AGENTS.md should fail"

echo "agents-md budget lint self-test passed"
