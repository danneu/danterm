#!/usr/bin/env bash
# Turns a package's type-check budget into a gate verdict.
#
# This script is both halves of the budget: it arms the measurement and it reads
# the result. It appends the frontend flags to the build command it is handed, so
# the compiler reports every function body it type-checks over the limit, and it
# then fails the step when the build reported a body in the measured package.
#
# The limit lives here rather than in `lib/TerminalCore/Package.swift` because
# `-Xfrontend` is only expressible through `.unsafeFlags`, which SwiftPM refuses
# from a versioned dependency -- a manifest that carries it can only ever be
# consumed by path. Keeping the flags on the gate's command line leaves the engine
# packages publishable. The cost is that this lane is now the only build that
# measures type-check cost; `scripts/run-test-suite.sh` runs it in the tooling and
# exhaustive suites rather than making the product suite rebuild into a second tree.
#
# It takes the whole command rather than composing one, for two reasons. The
# command stays legible in `scripts/run-test-suite.sh`, beside the ordinary product
# test lane whose build cache developers reuse. The self-test can also hand this
# script a canned-output runner instead of a compiler, so the verdict is proven
# without waiting on a build.
#
# What this cannot see is a body the build did not have to re-type-check. That is
# why the gate keeps its own scratch tree -- see `scripts/run-test-suite.sh`.
set -euo pipefail

# The budget, and the only place it is written down. `-debug-diagnostic-names`
# puts the stable identifier `debug_long_function_body` in the warning, so the
# verdict below keys on that instead of on the warning's prose.
BUDGET_MS=500
budget_flags=(
    -Xswiftc -Xfrontend -Xswiftc "-warn-long-function-bodies=$BUDGET_MS"
    -Xswiftc -Xfrontend -Xswiftc -debug-diagnostic-names
)

usage() {
    cat >&2 <<'USAGE'
usage: type-check-budget-gate.sh <command> [args...]

The command must be a `swift test`/`swift build` invocation carrying both
--package-path and --scratch-path. Example:

    type-check-budget-gate.sh swift test \
        --package-path <package> --scratch-path <repo>/.build-gate/<lane>

The gate appends the measurement flags itself; do not pass them.

The scratch path has to be a tree no other command warms, or the gate measures
nothing. `scripts/run-test-suite.sh` holds the invocation the gate uses.
USAGE
    exit 2
}

fail() { echo "type-check-budget-gate: $*" >&2; exit 1; }

(( $# > 0 )) || usage

# The package is what the budget covers; the scratch path is the measurement
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

[[ -f "$package/Package.swift" ]] \
    || fail "$package/Package.swift does not exist, so there is no package to measure."

# The verdict compares each diagnostic's path against this, so it has to be the
# resolved one: the compiler prints physical paths, and a package reached through
# a symlink would otherwise match nothing.
package_root="$(cd "$package" && pwd -P)"

echo "type-check-budget-gate: budgeting every body in $package_root at ${BUDGET_MS}ms; running:"
printf '    %s\n' "$* ${budget_flags[*]}"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# The command's own output is replayed as it happens, so a test failure stays
# diagnosable in exactly the block the gate prints for a failed step.
set +e
"$@" "${budget_flags[@]}" 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
set -e

# The flags reach every target in the build graph, dependencies included, so the
# diagnostics are split by where the body lives. Only the measured package's own
# sources are this budget's business.
#
# The leading-column filter drops the source excerpt the compiler prints under
# each diagnostic: its marker line repeats the message and the identifier, but it
# is indented, while a real diagnostic starts with its location.
breaches=()
unjudged=()
while IFS= read -r line; do
    case "$line" in
        "$package_root"/*) breaches+=("$line") ;;
        *) unjudged+=("$line") ;;
    esac
done < <(grep -F -- '[debug_long_function_body]' "$out" | grep -E '^[^[:space:]]' || true)

if (( ${#unjudged[@]} > 0 )); then
    echo >&2
    echo "type-check-budget-gate: over-budget bodies outside $package_root, which this gate did not judge:" >&2
    printf '    %s\n' "${unjudged[@]}" >&2
fi

if (( ${#breaches[@]} > 0 )); then
    echo >&2
    echo "type-check-budget-gate: function bodies over the ${BUDGET_MS}ms type-check budget:" >&2
    printf '%s\n' "${breaches[@]}" >&2
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

echo "type-check-budget-gate: no function body exceeded the ${BUDGET_MS}ms budget"
