#!/usr/bin/env bash
# Contract tests for the operator-facing benchmark command surface: the two
# stable paired comparison recipes, the retained diagnostic profiling and
# microbenchmark recipes, and the absence of any durable benchmark history.
# The recipes are what an operator types, so they are checked by running `just`
# in dry-run mode rather than by grepping the recipe bodies: that proves the
# documented `name=value` inputs actually reach the comparison runner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JUSTFILE="$ROOT/justfile"
COMPARE="$ROOT/scripts/terminal-benchmark-compare.py"
PROFILE="$ROOT/scripts/terminal-benchmark-profile.sh"
DRAW="$ROOT/scripts/terminal-draw-acceptance.py"

dry_run() {
    just --justfile "$JUSTFILE" --working-directory "$ROOT" --dry-run "$@" 2>&1
}

expect_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "expected command line to contain: $needle" >&2
        echo "actual: $haystack" >&2
        exit 1
    fi
}

# quick names one baseline revision and exactly one workload; confirm names only
# the baseline and never a workload, because it always runs the whole ladder.
quick="$(dry_run benchmark-quick baseline=v0.1.0 workload=terminal-feed)"
expect_contains "$quick" "terminal-benchmark-compare.py quick"
expect_contains "$quick" '--baseline "v0.1.0"'
expect_contains "$quick" '--workload "terminal-feed"'

confirm="$(dry_run benchmark-confirm baseline=v0.1.0)"
expect_contains "$confirm" "terminal-benchmark-compare.py confirm"
expect_contains "$confirm" '--baseline "v0.1.0"'
if [[ "$confirm" == *"--workload"* ]]; then
    echo "benchmark-confirm must not select a workload" >&2
    exit 1
fi

if just --justfile "$JUSTFILE" --working-directory "$ROOT" --dry-run benchmark-confirm \
    baseline=v0.1.0 workload=terminal-feed >/dev/null 2>&1; then
    echo "benchmark-confirm must reject a workload argument" >&2
    exit 1
fi

# The comparison runner refuses a baseline-free invocation outright: no mode may
# infer the baseline from HEAD, merge-base, history, or the candidate.
if python3 "$COMPARE" quick --workload terminal-feed >/dev/null 2>&1; then
    echo "the comparison runner must require an explicit baseline" >&2
    exit 1
fi

# The opt-in GUI proof surface is a stable recipe alongside test-terminal-viability.
grep -q '^test-terminal-benchmark-gui:' "$JUSTFILE"

# The retained diagnostic surface: profiling and the two microbenchmarks.
for recipe in benchmark-loop benchmark-sample benchmark-trace benchmark-draw benchmark-draw-app; do
    grep -qE "^${recipe}( |:)" "$JUSTFILE" || {
        echo "missing retained diagnostic recipe: $recipe" >&2
        exit 1
    }
done

# The unpaired history surface is gone, recipes and files together.
for recipe in 'benchmark' 'benchmark-one' 'benchmark-core' 'benchmark-redraw'; do
    if grep -qE "^${recipe}( \*?args)?:" "$JUSTFILE"; then
        echo "unpaired history recipe still present: $recipe" >&2
        exit 1
    fi
done
for path in benchmarks/results scripts/terminal-benchmark-suite.py; do
    if [[ -e "$ROOT/$path" ]]; then
        echo "unpaired benchmark history artifact still present: $path" >&2
        exit 1
    fi
done

# No benchmark, profiling, or microbenchmark command reads or writes a durable
# history file, so no result can form a cross-session regression claim.
if grep -rn -e 'terminal-app\.jsonl' -e 'terminal-redraw\.jsonl' -e 'benchmarks/results' \
    "$ROOT/scripts" "$ROOT/justfile" "$ROOT/app" "$ROOT/agent-docs" \
    --exclude="$(basename "$0")" --exclude-dir=__pycache__; then
    echo "a benchmark command or operator instruction still references history" >&2
    exit 1
fi
grep -q 'historyEligible: false' "$PROFILE"
if grep -q 'HISTORY_PATH' "$DRAW"; then
    echo "the draw microbenchmark must not own a history path" >&2
    exit 1
fi

echo "terminal benchmark command contract: ok"
