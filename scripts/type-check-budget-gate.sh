#!/usr/bin/env bash
# Turns a package's type-check budget into a gate verdict.
#
# `lib/TerminalCore/Package.swift` carries the budget as a shared `SwiftSetting`,
# so every build of that package measures every function body it type-checks. The
# compiler only warns, though, and the gate's worker throws away a passing step's
# output -- which is how a 710 ms regression sat unread for five days. This script
# is the reader: it runs the test command it is given, and fails the step when the
# build reported any body over budget.
#
# It takes the whole command rather than composing one, for two reasons. The
# command stays legible in `scripts/run-test-suite.sh`, where
# `scripts/gate-test-coverage-lint.py` reads it as the package's one test lane. The
# self-test can also hand this script a canned-output runner instead of a compiler,
# so the verdict is proven without waiting on a build.
#
# The manifest check is this script's own precondition, not a separate lint. A
# target added without the shared setting would compile unmeasured, and a heavy
# step that passed vacuously is worse than no step: the run would stay green while
# measuring nothing.
#
# What this cannot see is a body the build did not have to re-type-check. That is
# why the gate keeps its own scratch tree -- see `scripts/run-test-suite.sh`.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: type-check-budget-gate.sh <command> [args...]

The command must be a `swift test`/`swift build` invocation carrying both
--package-path and --scratch-path. Example:

    type-check-budget-gate.sh swift test \
        --package-path <package> --scratch-path <repo>/.build-gate/<lane>

The scratch path has to be a tree no other command warms, or the gate measures
nothing. `scripts/run-test-suite.sh` holds the invocation the gate uses.
USAGE
    exit 2
}

fail() { echo "type-check-budget-gate: $*" >&2; exit 1; }

(( $# > 0 )) || usage

# The package is where the budget is declared; the scratch path is the measurement
# window. A missing scratch path is refused rather than defaulted: falling back to
# the shared tree would hand the recompile -- and with it the measurement -- to
# whoever built first, and the step would pass having measured nothing.
package="."
scratch=""
for (( i = 1; i <= $#; i++ )); do
    case "${!i}" in
        --package-path) next=$(( i + 1 )); package="${!next:-}" ;;
        --package-path=*) package="${!i#--package-path=}" ;;
        --scratch-path) next=$(( i + 1 )); scratch="${!next:-}" ;;
        --scratch-path=*) scratch="${!i#--scratch-path=}" ;;
    esac
done

[[ -n "$scratch" ]] || fail "the command carries no --scratch-path.
    The gate measures only what its own build has to recompile, so it needs a
    build tree no other command warms. Name one in the step string."

manifest="$package/Package.swift"
[[ -f "$manifest" ]] || fail "$manifest does not exist, so there is no budget to enforce."

# The budget is one shared value carried by every target, so the check reads the
# binding's name out of the manifest instead of hardcoding it.
setting="$(sed -n 's/^let \([A-Za-z_][A-Za-z0-9_]*\): SwiftSetting = \.unsafeFlags(\[.*/\1/p' \
    "$manifest" | head -1)"
[[ -n "$setting" ]] || fail "$manifest declares no shared SwiftSetting for the budget.
    This gate would then have nothing to enforce and would pass vacuously.
    Expected a top-level \`let <name>: SwiftSetting = .unsafeFlags([...])\`."

grep -q -- '-warn-long-function-bodies=' "$manifest" \
    || fail "$manifest's \`$setting\` sets no -warn-long-function-bodies limit, so no
    function body is measured and this gate would pass vacuously."
# Diagnostic names put a stable identifier in the warning. Without them the only
# thing left to key on is the sentence, which a toolchain is free to reword.
grep -q -- '-debug-diagnostic-names' "$manifest" \
    || fail "$manifest's \`$setting\` omits -debug-diagnostic-names, so a breach is
    reported as prose only and this gate cannot recognize it."

limit="$(sed -n 's/.*-warn-long-function-bodies=\([0-9][0-9]*\).*/\1/p' "$manifest" | head -1)"

# Every target carries the setting, or the ones that do not are named. A target
# that opts out compiles unmeasured while the step still reports success.
unbudgeted="$(awk -v setting="$setting" '
    /^[[:space:]]*\.(target|executableTarget|testTarget)\(/ {
        if (inTarget && !hasBudget) print name
        inTarget = 1; hasBudget = 0; name = "<unnamed target>"
    }
    inTarget && name == "<unnamed target>" && match($0, /name: "[^"]+"/) {
        name = substr($0, RSTART + 7, RLENGTH - 8)
    }
    inTarget && index($0, "swiftSettings:") && index($0, setting) { hasBudget = 1 }
    END { if (inTarget && !hasBudget) print name }
' "$manifest")"

if [[ -n "$unbudgeted" ]]; then
    echo "type-check-budget-gate: $manifest declares targets that do not carry \`$setting\`:" >&2
    while IFS= read -r target; do printf '    %s\n' "$target" >&2; done <<<"$unbudgeted"
    echo "    Every target carries the budget, or the ones that skip it build unmeasured." >&2
    exit 1
fi

echo "type-check-budget-gate: $manifest budgets every target at ${limit}ms; running:"
printf '    %s\n' "$*"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# The command's own output is replayed as it happens, so a test failure stays
# diagnosable in exactly the block the gate prints for a failed step.
set +e
"$@" 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
set -e

# Keyed on the compiler's diagnostic identifier, not on the sentence around it. A
# reworded warning still fails the gate; a toolchain that renames the identifier
# is the one thing this cannot survive, and there is nothing more stable on offer.
breaches="$(grep -F '[debug_long_function_body]' "$out" || true)"

if [[ -n "$breaches" ]]; then
    echo >&2
    echo "type-check-budget-gate: function bodies over the ${limit}ms type-check budget:" >&2
    printf '%s\n' "$breaches" >&2
    echo >&2
    echo "    Reshape the expression, do not raise the limit: this cost is expression" >&2
    echo "    shape, and a limit above it stops catching the class. Annotate the" >&2
    echo "    oversized inference sites -- locals and closure signatures -- and leave" >&2
    echo "    every assertion alone." >&2
    exit 1
fi

if (( rc != 0 )); then
    fail "the command failed (exit $rc). Its output is above."
fi

echo "type-check-budget-gate: no function body exceeded the ${limit}ms budget"
