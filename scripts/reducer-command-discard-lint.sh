#!/usr/bin/env bash
# Reject a production call that drops the reducer's commands.
#
# `update()` keeps `@discardableResult` so a test can call it for its mutation
# alone, but that same attribute makes a dropped command list silent in
# production: a nested arm that later gains a command becomes a no-op nobody
# compiles a warning for. Every production call must therefore feed its result
# into the command list its caller returns, and this gate is what makes that an
# error rather than a warning nobody reads in captured gate output.
#
# The rule is positional, because a Swift statement starts a line: a call whose
# result is consumed always has something in front of it (`let x = `, `return `,
# `commands += `), so a line whose first token is the call itself -- with or
# without a leading `_ = ` -- is a discard.
#
# There is no per-line escape marker on purpose. No legitimate production
# discard exists, so a future one is a decision to argue, not to annotate.
#
# Like its siblings in scripts/, this is a grep heuristic: a discard spelled in
# a shape it does not match would pass. The self-test pins the shapes that
# exist, and propagation at the six call sites -- not this gate -- is what makes
# them correct today.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Production roots only. The test trees (app-tests/, tests-ui/, lib/*/Tests/)
# are where calling the reducer for its mutation alone is legitimate.
ROOTS=("$ROOT/lib/DanTermCore/Sources" "$ROOT/app")
if [[ "$#" -gt 0 ]]; then
    ROOTS=("$@")
fi

# No -L in the sweep: app/DanTermCore and app/DanTermSupport are symlinks into lib/,
# and following them would scan the same file twice.
lint_resolve_targets "reducer-command-discard-lint" '*.swift' "${ROOTS[@]}"

if ! awk '
    {
        line = $0
        sub(/^[[:space:]]*/, "", line)
        if (line ~ /^\/\//) next
        if (line ~ /^\*/) next
        sub(/^_[[:space:]]*=[[:space:]]*/, "", line)
        sub(/^try[[:space:]]+/, "", line)
        if (line ~ /^update[[:space:]]*\(/) {
            printf("%s:%d: %s\n", FILENAME, FNR, $0) > "/dev/stderr"
            bad = 1
        }
    }
    END { exit bad ? 1 : 0 }
' "${LINT_TARGET_FILES[@]}"; then
    echo "reducer-command-discard-lint: a production update() call drops its commands" >&2
    echo "  add the nested result to the command list this arm returns" >&2
    exit 1
fi

echo "reducer command discard lint passed"
