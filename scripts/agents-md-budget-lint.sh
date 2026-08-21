#!/usr/bin/env bash
# Caps the length of the root AGENTS.md, the one file every agent loads before it
# reads anything else.
#
# This is a budget, not a style rule. AGENTS.md is prepended to every agent's
# context, so its length is paid on every task, and a rule that is never read is
# worse than no rule: published guidance on agent instruction files reports that
# instruction-following degrades across the *whole* file as it grows, so a
# paragraph added at the bottom makes the paragraph at the top less likely to be
# obeyed. The file passed 250 lines once already and had to be cut back by 40%.
#
# The cap is deliberately a hard failure rather than a warning. The fix when it
# trips is not to argue the number: it is to move the detail into agent-docs/ or
# docs/design/ and leave a pointer in the "Read before you touch it" table, which
# is what that table is for. Nothing is deleted; it stops being always-loaded.
set -euo pipefail

# Test seam: the self-test points the check at a fixture tree. Nothing else sets this.
REPO_ROOT="${AGENTS_MD_BUDGET_LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

MAX_LINES=250
TARGET="$REPO_ROOT/AGENTS.md"

if [[ ! -f "$TARGET" ]]; then
    echo "agents-md-budget-lint: no AGENTS.md at $TARGET" >&2
    echo "  the root agent instruction file is missing, so every agent starts this" >&2
    echo "  repository with no project context at all" >&2
    exit 1
fi

lines="$(wc -l <"$TARGET" | tr -d ' ')"

if (( lines > MAX_LINES )); then
    echo "agents-md-budget-lint: AGENTS.md is $lines lines, over the $MAX_LINES-line budget" >&2
    echo "  every agent loads this file before every task, and a longer file makes each" >&2
    echo "  rule in it less likely to be followed -- including the ones already there" >&2
    echo "  move the $(( lines - MAX_LINES )) lines of detail into agent-docs/ or docs/design/ and" >&2
    echo "  leave a row in the \"Read before you touch it\" table pointing at it" >&2
    exit 1
fi

echo "agents-md budget lint passed ($lines/$MAX_LINES lines)"
