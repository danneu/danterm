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
# Fifth positional is the Instruments template for `trace` and the warmup cutoff
# for `memory`; each mode reads only its own.
WARMUP="${5:-15}"
WORKLOAD="${WORKLOAD#workload=}"
BACKEND="${BACKEND#backend=}"
DURATION="${DURATION#seconds=}"
TEMPLATE="${TEMPLATE#template=}"
WARMUP="${WARMUP#warmup=}"
case "$MODE" in loop|sample|trace|memory) ;; *) echo "Unknown profiling mode: $MODE" >&2; exit 2 ;; esac
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo "Profiling duration must be whole seconds" >&2; exit 2; }
if [[ "$MODE" == memory ]]; then
    [[ "$WARMUP" =~ ^[0-9]+$ ]] || { echo "Memory warmup must be whole seconds" >&2; exit 2; }
    (( DURATION > WARMUP )) || { echo "Profiling duration must exceed the ${WARMUP}s warmup" >&2; exit 2; }
fi
for command in jq nm python3; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_ROOT="$REPO_ROOT/.build/terminal-benchmark-profiles/$(date +%Y-%m-%d-%H%M%S)-$$"
IDENTITY_PATH="$PROFILE_ROOT/identity.json"
HARNESS_IDENTITY_PATH="$PROFILE_ROOT/harness-identity.json"
HARNESS_LOG="$PROFILE_ROOT/harness.log"
HARNESS_PID=""
mkdir -p "$PROFILE_ROOT"
trap 'terminate_owned_pid "$HARNESS_PID"' EXIT INT TERM

case "$WORKLOAD" in
    scrollback-stream)
        fixture_identity="$(jq -er '.workloads["scrollback-stream"].identity' "$REPO_ROOT/benchmarks/fixtures/terminal-app.json")"
        reset_behavior="fresh deterministic corpus replay; steady-state app/session caches intentionally persist"
        redraw_updates=0
        ;;
    full-screen-content-churn)
        fixture_identity="full-screen-content-churn-v2-serialized-179x66"
        reset_behavior="full-screen deterministic setup plus excluded settling draw before serialized draws"
        redraw_updates=1000000
        ;;
    full-screen-style-churn)
        fixture_identity="full-screen-style-churn-v2-serialized-179x66"
        reset_behavior="full-screen deterministic setup plus excluded settling draw before serialized draws"
        redraw_updates=1000000
        ;;
    full-screen-incremental-mixed-churn)
        fixture_identity="full-screen-incremental-mixed-churn-v2-four-rows-six-damage-179x66"
        reset_behavior="dense deterministic setup plus excluded settling draw before four-row content-and-style updates with six-row glyph-halo damage"
        redraw_updates=1000000
        ;;
    *)
        echo "Unsupported sustained app profiling workload: $WORKLOAD" >&2
        exit 2
        ;;
esac

DANTERM_BENCHMARK_MODE=loop DANTERM_BENCHMARK_PROFILING=1 \
    DANTERM_BENCHMARK_IDENTITY_PATH="$HARNESS_IDENTITY_PATH" \
    DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES="$redraw_updates" \
    "$SCRIPT_DIR/terminal-benchmark.sh" "$WORKLOAD" "$BACKEND" >"$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!
deadline=$((SECONDS + 120))
while [[ ! -f "$HARNESS_IDENTITY_PATH" ]]; do
    kill -0 "$HARNESS_PID" 2>/dev/null || { echo "Profiling benchmark failed; see $HARNESS_LOG" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "Timed out waiting for profiling identity; see $HARNESS_LOG" >&2; exit 1; }
    sleep 0.1
done

target_pid="$(jq -er '.pid' "$HARNESS_IDENTITY_PATH")"
binary="$(jq -er '.binary' "$HARNESS_IDENTITY_PATH")"
kill -0 "$target_pid" 2>/dev/null || { echo "Published profiling pid is no longer running" >&2; exit 1; }
cp "$binary" "$PROFILE_ROOT/DanTerm-Benchmark-symbols"
nm -nm "$binary" >"$PROFILE_ROOT/symbols.txt"
binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
mach_o_uuid="$(dwarfdump --uuid "$binary" | awk 'NR == 1 {print $2}')"
source_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
source_tree="$(git -C "$REPO_ROOT" rev-parse "HEAD^{tree}")"
dirty_state_sha256="$(
    {
        git -C "$REPO_ROOT" diff --binary HEAD
        git -C "$REPO_ROOT" ls-files --others --exclude-standard |
            while IFS= read -r path; do
                printf '%s\n' "$path"
                shasum -a 256 "$REPO_ROOT/$path"
            done
    } | shasum -a 256 | awk '{print $1}'
)"
jq --arg fixtureIdentity "$fixture_identity" --arg resetBehavior "$reset_behavior" \
    --arg binarySHA256 "$binary_sha256" --arg machOUUID "$mach_o_uuid" \
    --arg sourceCommit "$source_commit" --arg sourceTree "$source_tree" \
    --arg dirtyStateSHA256 "$dirty_state_sha256" --arg artifactRoot "$PROFILE_ROOT" \
    '. + {
        schemaVersion: 2,
        geometry: .geometry,
        fixtureIdentity: $fixtureIdentity,
        resetBehavior: $resetBehavior,
        binarySHA256: $binarySHA256,
        machOUUID: $machOUUID,
        sourceIdentity: {
            commit: $sourceCommit,
            sourceTree: $sourceTree,
            dirtyStateSHA256: $dirtyStateSHA256
        },
        artifactRoot: $artifactRoot,
        decisionEligible: false,
        historyEligible: false,
        profiledTimingsAreDiagnosticOnly: true
    }' "$HARNESS_IDENTITY_PATH" >"$IDENTITY_PATH"

case "$MODE" in
    loop)
        cat "$IDENTITY_PATH"
        echo "Sustained benchmark running; artifacts: $PROFILE_ROOT" >&2
        wait "$HARNESS_PID"
        ;;
    sample)
        command -v sample >/dev/null || { echo "sample is unavailable on this macOS host" >&2; exit 1; }
        printf 'sample %s %s -mayDie -fullPaths -file %s\n' \
            "$target_pid" "$DURATION" "$PROFILE_ROOT/sample.txt" >"$PROFILE_ROOT/profile-command.txt"
        if ! sample "$target_pid" "$DURATION" -mayDie -fullPaths -file "$PROFILE_ROOT/sample.txt"; then
            echo "sample could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
            exit 1
        fi
        echo "Sample profile: $PROFILE_ROOT/sample.txt"
        python3 "$SCRIPT_DIR/terminal-profile-report.py" "$PROFILE_ROOT/sample.txt"
        ;;
    memory)
        for command in footprint leaks heap; do
            command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
        done
        printf 'terminal-memory-profile.py %s --seconds %s --warmup %s\n' \
            "$target_pid" "$DURATION" "$WARMUP" >"$PROFILE_ROOT/profile-command.txt"
        python3 "$SCRIPT_DIR/terminal-memory-profile.py" "$target_pid" \
            --output "$PROFILE_ROOT" --seconds "$DURATION" --warmup "$WARMUP"
        ;;
    trace)
        command -v xcrun >/dev/null || { echo "xcrun is unavailable; install Xcode command-line tools" >&2; exit 1; }
        printf 'xcrun xctrace record --no-prompt --template %s --attach %s --time-limit %ss --output %s\n' \
            "$TEMPLATE" "$target_pid" "$DURATION" "$PROFILE_ROOT/profile.trace" >"$PROFILE_ROOT/profile-command.txt"
        if ! xcrun xctrace record --no-prompt --template "$TEMPLATE" --attach "$target_pid" \
            --time-limit "${DURATION}s" --output "$PROFILE_ROOT/profile.trace"; then
            echo "xctrace could not attach to pid $target_pid. Grant Developer Tools access to this shell and retry." >&2
            exit 1
        fi
        xcrun xctrace export --input "$PROFILE_ROOT/profile.trace" --toc --output "$PROFILE_ROOT/trace-toc.xml"
        # Only the CPU templates record a time-profile table. Recording with a
        # memory template succeeds and then exports nothing, so name the mismatch
        # here rather than leaving an empty export to be read as an idle process.
        if ! grep -q 'schema="time-profile"' "$PROFILE_ROOT/trace-toc.xml"; then
            echo "Template '$TEMPLATE' recorded no time-profile table; nothing to export." >&2
            echo "Schemas present in $PROFILE_ROOT/trace-toc.xml:" >&2
            grep -o 'schema="[a-z0-9-]*"' "$PROFILE_ROOT/trace-toc.xml" | sort -u >&2
            echo "For memory, use: just benchmark-memory $WORKLOAD" >&2
            exit 1
        fi
        # The .trace bundle opens only in Instruments and the table of contents
        # carries no samples, so export the time-profile rows themselves; that
        # table is the only artifact here a non-interactive reader can use.
        xcrun xctrace export --input "$PROFILE_ROOT/profile.trace" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
            --output "$PROFILE_ROOT/time-profile.xml"
        echo "Trace profile: $PROFILE_ROOT/profile.trace"
        echo "Trace export: $PROFILE_ROOT/trace-toc.xml"
        echo "Sample export: $PROFILE_ROOT/time-profile.xml"
        python3 "$SCRIPT_DIR/terminal-profile-report.py" "$PROFILE_ROOT/time-profile.xml"
        ;;
esac
