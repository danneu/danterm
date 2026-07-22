#!/usr/bin/env bash
# Attach a command-line profiler to one isolated sustained benchmark app.
set -euo pipefail

terminate_owned_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

MODE="${1:-loop}"
WORKLOAD="${2:-scrollback-stream}"
BACKEND="${3:-swift}"
DURATION="${4:-15}"
TEMPLATE="${5:-Time Profiler}"
WORKLOAD="${WORKLOAD#workload=}"
BACKEND="${BACKEND#backend=}"
DURATION="${DURATION#seconds=}"
TEMPLATE="${TEMPLATE#template=}"
case "$MODE" in loop|sample|trace) ;; *) echo "Unknown profiling mode: $MODE" >&2; exit 2 ;; esac
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo "Profiling duration must be whole seconds" >&2; exit 2; }
for command in jq nm; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_ROOT="$REPO_ROOT/.build/terminal-benchmark-profiles/$(date +%Y-%m-%d-%H%M%S)-$$"
IDENTITY_PATH="$PROFILE_ROOT/identity.json"
HARNESS_LOG="$PROFILE_ROOT/harness.log"
HARNESS_PID=""
mkdir -p "$PROFILE_ROOT"
trap 'terminate_owned_pid "$HARNESS_PID"' EXIT INT TERM

DANTERM_BENCHMARK_MODE=loop DANTERM_BENCHMARK_PROFILING=1 \
    DANTERM_BENCHMARK_IDENTITY_PATH="$IDENTITY_PATH" \
    "$SCRIPT_DIR/terminal-benchmark.sh" "$WORKLOAD" "$BACKEND" >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!
deadline=$((SECONDS + 120))
while [[ ! -f "$IDENTITY_PATH" ]]; do
    kill -0 "$HARNESS_PID" 2>/dev/null || { echo "Profiling benchmark failed; see $HARNESS_LOG" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "Timed out waiting for profiling identity; see $HARNESS_LOG" >&2; exit 1; }
    sleep 0.1
done

target_pid="$(jq -er '.pid' "$IDENTITY_PATH")"
binary="$(jq -er '.binary' "$IDENTITY_PATH")"
kill -0 "$target_pid" 2>/dev/null || { echo "Published profiling pid is no longer running" >&2; exit 1; }
cp "$binary" "$PROFILE_ROOT/DanTerm-Benchmark-symbols"
nm -nm "$binary" >"$PROFILE_ROOT/symbols.txt"

case "$MODE" in
    loop)
        cat "$IDENTITY_PATH"
        echo "Sustained benchmark running; artifacts: $PROFILE_ROOT" >&2
        wait "$HARNESS_PID"
        ;;
    sample)
        command -v sample >/dev/null || { echo "sample is unavailable on this macOS host" >&2; exit 1; }
        if ! sample "$target_pid" "$DURATION" -mayDie -fullPaths -file "$PROFILE_ROOT/sample.txt"; then
            echo "sample could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
            exit 1
        fi
        echo "Sample profile: $PROFILE_ROOT/sample.txt"
        ;;
    trace)
        command -v xcrun >/dev/null || { echo "xcrun is unavailable; install Xcode command-line tools" >&2; exit 1; }
        if ! xcrun xctrace record --no-prompt --template "$TEMPLATE" --attach "$target_pid" \
            --time-limit "${DURATION}s" --output "$PROFILE_ROOT/profile.trace"; then
            echo "xctrace could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
            exit 1
        fi
        xcrun xctrace export --input "$PROFILE_ROOT/profile.trace" --toc --output "$PROFILE_ROOT/trace-toc.xml"
        echo "Trace profile: $PROFILE_ROOT/profile.trace"
        echo "Trace export: $PROFILE_ROOT/trace-toc.xml"
        ;;
esac
