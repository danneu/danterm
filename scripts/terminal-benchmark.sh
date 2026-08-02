#!/usr/bin/env bash
# Run one isolated optimized real-app terminal benchmark and emit its metrics as JSON.
set -euo pipefail

terminate_owned_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for _attempt in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

front_owned_app() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || {
        echo "Benchmark app PID must be numeric" >&2
        return 1
    }
    /usr/bin/osascript -e \
        "tell application \"System Events\" to set frontmost of first process whose unix id is $pid to true"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

WORKLOAD="${1:-scrollback-stream}"
BACKEND="${2:-swift}"
BACKEND="${BACKEND#backend=}"
MODE="${DANTERM_BENCHMARK_MODE:-measure}"
PROFILE_IDENTITY_PATH="${DANTERM_BENCHMARK_IDENTITY_PATH:-}"
PHASE_LOG="${DANTERM_BENCHMARK_PHASE_LOG:-}"
BUNDLE_SUFFIX="${DANTERM_BENCHMARK_BUNDLE_SUFFIX:-}"
TARGET_COLUMNS="${DANTERM_TERMINAL_BENCHMARK_COLUMNS:-179}"
TARGET_ROWS="${DANTERM_TERMINAL_BENCHMARK_ROWS:-66}"
LOCALIZED_UPDATES="${DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES:-0}"
REDRAW_UPDATES="${DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES:-0}"
CORPUS_PATH="$(cd "$(dirname "$0")/.." && pwd)/benchmarks/fixtures/terminal-app.json"
case "$BACKEND" in
    swift|ghostty) ;;
    *) echo "Unknown backend: $BACKEND (expected swift or ghostty)" >&2; exit 2 ;;
esac
case "$MODE" in
    measure|loop|persistent) ;;
    *) echo "Unknown benchmark mode: $MODE" >&2; exit 2 ;;
esac
# Closed set: the paired arms share the empty namespace the calibration froze,
# .a/.b remain for per-block scrollback isolation, .bystander is reserved for the
# GUI ownership proof's deliberately unrelated instance, and .isolation for its
# block-isolation proof -- which drives blocks but measures nothing, so it must
# not be mistaken for an arm whose numbers count.
case "$BUNDLE_SUFFIX" in
    ""|.a|.b|.bystander|.isolation) ;;
    *)
        echo "Benchmark bundle suffix must be empty, .a, .b, .bystander, or .isolation" >&2
        exit 2
        ;;
esac
if [[ "$MODE" != "measure" && -z "$PROFILE_IDENTITY_PATH" ]]; then
    echo "Persistent benchmark modes require DANTERM_BENCHMARK_IDENTITY_PATH" >&2
    exit 2
fi
if [[ ! "$TARGET_COLUMNS" =~ ^[1-9][0-9]*$ || ! "$TARGET_ROWS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Benchmark geometry must use positive integer columns and rows" >&2
    exit 2
fi

for command in codesign jq plutil swift; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
# Closed set, not a glob: the producer emits stimulus only for these five draw
# workloads plus the diagnostic localized microbenchmark. Anything else must come
# from the committed corpus, so a typo or a deleted workload fails here.
case "$WORKLOAD" in
    localized-draw-acceptance \
    | full-screen-content-churn \
    | full-screen-style-churn \
    | full-screen-incremental-mixed-churn \
    | sparse-spans-few \
    | sparse-spans-max) ;;
    *)
        jq -e --arg workload "$WORKLOAD" '.workloads[$workload] != null' "$CORPUS_PATH" >/dev/null || {
            echo "Unknown workload: $WORKLOAD" >&2
            exit 2
        }
        ;;
esac
FIXTURE_IDENTITY="$(jq -r --arg workload "$WORKLOAD" \
    '.workloads[$workload].identity // $workload' "$CORPUS_PATH")"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_PATH="$REPO_ROOT/.build/terminal-benchmark-swiftpm"
RUN_ROOT="$REPO_ROOT/.build/terminal-benchmark-runs/$(date +%Y-%m-%d-%H%M%S)-$$"
RUNTIME_ROOT="$(mktemp -d /private/tmp/dtb.XXXXXX)"
APP_PATH="$RUN_ROOT/DanTerm Benchmark.app"
ARTIFACTS="$RUN_ROOT/artifacts"
HOME_DIR="$RUNTIME_ROOT/home"
TMP_DIR="$RUNTIME_ROOT/tmp"
ZDOTDIR="$RUNTIME_ROOT/zdotdir"
START_MARKER="DANTERM-BENCH-START-$$"
COMPLETION_MARKER="DANTERM-BENCH-COMPLETE-$$"
EXPECTED_FINAL_STATE="DANTERM-BENCH-FINAL-STATE-$$"
START_ACK="$ARTIFACTS/start-ack"
START_DRAW_ACK="$ARTIFACTS/start-draw-ack"
READY_DRAW_ACK="$ARTIFACTS/ready-draw-ack"
LOCALIZED_DRAW_ACK_PREFIX="$ARTIFACTS/localized-draw"
DRAW_RESULT="$ARTIFACTS/final-draw.json"
STATE_RESULT="$ARTIFACTS/block-state.json"
PRODUCER_RESULT="$ARTIFACTS/producer-write.json"
GEOMETRY_READY="$ARTIFACTS/geometry-ready"
PATH_PROBE="$ARTIFACTS/path-probe.json"
APP_LOG="$ARTIFACTS/app.log"
APP_PID=""
mkdir -p "$ARTIFACTS" "$HOME_DIR" "$TMP_DIR" "$ZDOTDIR"

record_phase() {
    [[ -n "$PHASE_LOG" ]] || return 0
    mkdir -p "$(dirname "$PHASE_LOG")"
    printf '%s %s\n' "$(python3 -c 'import time; print(time.monotonic_ns())')" "$1" >>"$PHASE_LOG"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    terminate_owned_pid "$APP_PID"
    record_phase "teardown-complete"
    rm -rf "$RUNTIME_ROOT"
    if [[ $status -ne 0 ]]; then
        echo "Benchmark failed; diagnostics preserved at: $ARTIFACTS" >&2
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

cat >"$ZDOTDIR/.zshenv" <<'EOF'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export HISTFILE=/dev/null
EOF
cat >"$ZDOTDIR/.zshrc" <<'EOF'
PROMPT=''
RPROMPT=''
EOF

record_phase "build-start"
swift build --package-path "$REPO_ROOT" --build-path "$BUILD_PATH" --configuration release \
    -Xswiftc -DDANTERM_TERMINAL_BENCHMARK >&2
BIN_PATH="$(swift build --package-path "$REPO_ROOT" --build-path "$BUILD_PATH" \
    --configuration release -Xswiftc -DDANTERM_TERMINAL_BENCHMARK --show-bin-path)"
swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --build-path "$BUILD_PATH/TerminalPTY" \
    --configuration release --product PTYSessionBootstrap >&2
BOOTSTRAP_BIN_PATH="$(swift build --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$BUILD_PATH/TerminalPTY" --configuration release --show-bin-path)"
record_phase "build-complete"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm Benchmark"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
cp "$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap" "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
chmod +x "$APP_PATH/Contents/MacOS/DanTerm Benchmark" "$APP_PATH/Contents/Helpers/danterm" \
    "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
cp "$REPO_ROOT/app/Info.plist" "$APP_PATH/Contents/Info.plist"
# Keep stable benchmark-only A/B identities; never suffix with the run PID. The
# stable identities avoid repeated first-launch privacy prompts, while isolated
# homes and bundle-specific cache paths keep concurrent A/B sockets separate.
BUNDLE_ID="com.danneu.danterm-terminal-benchmark${BUNDLE_SUFFIX}"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "DanTerm Benchmark" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "DanTerm Benchmark" "$APP_PATH/Contents/Info.plist"
plutil -remove CFBundleIconName "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
"$SCRIPT_DIR/bundle-theme-resources.sh" "$REPO_ROOT" "$APP_PATH" >&2
codesign --force --deep --sign - --entitlements "$SCRIPT_DIR/terminal-benchmark-entitlements.plist" "$APP_PATH" >/dev/null
codesign -d --entitlements :- "$APP_PATH" 2>&1 | grep -q '<key>com.apple.security.get-task-allow</key>' || {
    echo "Benchmark app is missing the get-task-allow profiling entitlement" >&2
    exit 1
}
record_phase "assemble-sign-complete"

env HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" TMPDIR="$TMP_DIR/" ZDOTDIR="$ZDOTDIR" \
    DANTERM_TERMINAL_BACKEND="$BACKEND" \
    DANTERM_TERMINAL_CHARACTERIZATION_PATH_PROBE="$PATH_PROBE" \
    DANTERM_TERMINAL_CHARACTERIZATION_TEMP_ROOT="$TMP_DIR" \
    DANTERM_TERMINAL_BENCHMARK_START_MARKER="$START_MARKER" \
    DANTERM_TERMINAL_BENCHMARK_COMPLETION_MARKER="$COMPLETION_MARKER" \
    DANTERM_TERMINAL_BENCHMARK_EXPECTED_FINAL_STATE="$EXPECTED_FINAL_STATE" \
    DANTERM_TERMINAL_BENCHMARK_START_ACK="$START_ACK" \
    DANTERM_TERMINAL_BENCHMARK_START_DRAW_ACK="$START_DRAW_ACK" \
    DANTERM_TERMINAL_BENCHMARK_READY_DRAW_ACK="$READY_DRAW_ACK" \
    DANTERM_TERMINAL_BENCHMARK_LOCALIZED_DRAW_ACK_PREFIX="$LOCALIZED_DRAW_ACK_PREFIX" \
    DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES="$LOCALIZED_UPDATES" \
    DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES="$REDRAW_UPDATES" \
    DANTERM_TERMINAL_BENCHMARK_RESULT="$DRAW_RESULT" \
    DANTERM_TERMINAL_BENCHMARK_STATE_RESULT="$STATE_RESULT" \
    DANTERM_TERMINAL_BENCHMARK_PRODUCER_RESULT="$PRODUCER_RESULT" \
    DANTERM_TERMINAL_BENCHMARK_GEOMETRY_READY="$GEOMETRY_READY" \
    DANTERM_TERMINAL_BENCHMARK_BACKEND="$BACKEND" \
    DANTERM_TERMINAL_BENCHMARK_WORKLOAD="$WORKLOAD" \
    DANTERM_TERMINAL_BENCHMARK_COLUMNS="$TARGET_COLUMNS" \
    DANTERM_TERMINAL_BENCHMARK_ROWS="$TARGET_ROWS" \
    DANTERM_BENCHMARK_THERMAL_STATE_OVERRIDE="${DANTERM_BENCHMARK_THERMAL_STATE_OVERRIDE:-}" \
    DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH="${DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH:-}" \
    DANTERM_BENCHMARK_MODE="$MODE" \
    "$APP_PATH/Contents/MacOS/DanTerm Benchmark" >"$APP_LOG" 2>&1 &
APP_PID=$!
record_phase "launch-complete"

deadline=$((SECONDS + 20))
while [[ ! -f "$PATH_PROBE" ]]; do
    kill -0 "$APP_PID" 2>/dev/null || { echo "Benchmark app exited during startup" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark app" >&2; exit 1; }
    sleep 0.05
done
for key in home applicationSupport caches temporary config recovery socket replay; do
    value="$(jq -er --arg key "$key" '.[$key]' "$PATH_PROBE")"
    case "$value" in
        "$RUNTIME_ROOT"|"$RUNTIME_ROOT"/*|/tmp/"${RUNTIME_ROOT##*/}"|/tmp/"${RUNTIME_ROOT##*/}"/*) ;;
        *) echo "Benchmark path escaped isolated runtime: $key=$value" >&2; exit 1 ;;
    esac
done
CLI="$APP_PATH/Contents/Helpers/danterm"
export DANTERM_SOCK
DANTERM_SOCK="$(jq -er '.socket' "$PATH_PROBE")"
PANE_ID=""
while [[ -z "$PANE_ID" ]]; do
    model="$("$CLI" ls 2>"$ARTIFACTS/last-cli-error.txt" || true)"
    PANE_ID="$(printf '%s\n' "$model" | jq -r '.selectedTabId as $tab | .groups[].tabs[] | select(.id == $tab) | .focusedPaneId // empty' 2>/dev/null || true)"
    kill -0 "$APP_PID" 2>/dev/null || { echo "Benchmark app exited while waiting for a pane" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark pane" >&2; exit 1; }
    [[ -n "$PANE_ID" ]] || sleep 0.05
done
record_phase "app-ready"
front_owned_app "$APP_PID"

printf -v command 'python3 %q' "$SCRIPT_DIR/terminal-benchmark-producer.py"
"$CLI" pane input --pane "$PANE_ID" --literal -- "$command"
"$CLI" pane input --pane "$PANE_ID" -- Enter
if [[ "$MODE" == "loop" || "$MODE" == "persistent" ]]; then
    deadline=$((SECONDS + 20))
    while [[ ! -f "$GEOMETRY_READY" ]]; do
        if [[ -f "$PRODUCER_RESULT" ]]; then
            producer_error="$(jq -r '.error // empty' "$PRODUCER_RESULT")"
            [[ -z "$producer_error" ]] || { echo "$producer_error" >&2; exit 1; }
        fi
        (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark geometry" >&2; exit 1; }
        sleep 0.05
    done
    record_phase "converge-complete"
    identity_tmp="$PROFILE_IDENTITY_PATH.tmp.$$"
    mkdir -p "$(dirname "$PROFILE_IDENTITY_PATH")"
    profiling_active=false
    [[ "${DANTERM_BENCHMARK_PROFILING:-0}" == "1" ]] && profiling_active=true
    geometry="$(jq -c --argjson columns "$TARGET_COLUMNS" --argjson rows "$TARGET_ROWS" \
        '{columns: $columns, rows: $rows}' <<<"{}")"
    jq -n --argjson pid "$APP_PID" --arg workload "$WORKLOAD" --arg backend "$BACKEND" \
        --arg binary "$APP_PATH/Contents/MacOS/DanTerm Benchmark" --arg artifacts "$ARTIFACTS" \
        --argjson geometry "$geometry" --argjson profilingActive "$profiling_active" \
        '{schemaVersion: 1, pid: $pid, workload: $workload, backend: $backend,
          binary: $binary, artifacts: $artifacts, geometry: $geometry,
          profilingActive: $profilingActive}' >"$identity_tmp"
    mv "$identity_tmp" "$PROFILE_IDENTITY_PATH"
    echo "Persistent benchmark identity: $PROFILE_IDENTITY_PATH" >&2
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.25; done
    wait "$APP_PID"
    exit $?
fi
deadline=$((SECONDS + 20))
while true; do
    if [[ -f "$STATE_RESULT" ]] && ! python3 "$SCRIPT_DIR/terminal-benchmark-state.py" "$STATE_RESULT" | jq -e '.valid' >/dev/null; then
        break
    fi
    if [[ -f "$PRODUCER_RESULT" ]]; then
        [[ -n "$(jq -r '.error // empty' "$PRODUCER_RESULT")" ]] && break
        [[ "$BACKEND" != "swift" || -f "$DRAW_RESULT" ]] && break
    fi
    (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark metrics" >&2; exit 1; }
    sleep 0.05
done
if [[ -f "$STATE_RESULT" ]]; then
    block_state="$(python3 "$SCRIPT_DIR/terminal-benchmark-state.py" "$STATE_RESULT")"
    if ! jq -e '.valid' <<<"$block_state" >/dev/null; then
        jq -n --arg backend "$BACKEND" --arg workload "$WORKLOAD" \
            --argjson blockState "$block_state" --slurpfile state "$STATE_RESULT" \
            '{
                schemaVersion: 1,
                backend: $backend,
                workload: $workload,
                blockState: $blockState,
                producerWrite: {available: false},
                finalDraw: {
                    available: false,
                    event: "block-invalidated",
                    machineStateSamples: $state[0].machineStateSamples
                }
            }'
        exit 0
    fi
fi
producer_error="$(jq -r '.error // empty' "$PRODUCER_RESULT")"
if [[ -n "$producer_error" ]]; then
    echo "$producer_error" >&2
    exit 1
fi

producer_elapsed="$(jq -er '.elapsedNanoseconds' "$PRODUCER_RESULT")"
geometry="$(jq -ec '.geometry' "$PRODUCER_RESULT")"
reported_columns="$(jq -er '.columns' <<<"$geometry")"
reported_rows="$(jq -er '.rows' <<<"$geometry")"
if [[ "$reported_columns" != "$TARGET_COLUMNS" || "$reported_rows" != "$TARGET_ROWS" ]]; then
    echo "Benchmark geometry mismatch: required ${TARGET_COLUMNS}x${TARGET_ROWS}, reported ${reported_columns}x${reported_rows}" >&2
    exit 1
fi
display_scale="$(jq -er '.displayScale' "$PATH_PROBE")"
if [[ "$BACKEND" == "swift" ]]; then
    draw_elapsed="$(jq -er '.elapsedNanoseconds' "$DRAW_RESULT")"
    (( draw_elapsed >= producer_elapsed )) || {
        echo "Invalid timing order: final draw preceded the producer's final write" >&2
        exit 1
    }
    block_state="$(python3 "$SCRIPT_DIR/terminal-benchmark-state.py" "$DRAW_RESULT")"
    jq -n --arg backend "$BACKEND" --arg workload "$WORKLOAD" --argjson geometry "$geometry" \
        --arg fixtureIdentity "$FIXTURE_IDENTITY" \
        --argjson processId "$APP_PID" --arg sessionId "$PANE_ID" \
        --argjson displayScale "$display_scale" \
        --argjson blockState "$block_state" \
        --slurpfile producer "$PRODUCER_RESULT" --slurpfile draw "$DRAW_RESULT" \
        '{schemaVersion: 1, backend: $backend, workload: $workload,
          fixtureIdentity: $fixtureIdentity, processId: $processId,
          sessionId: $sessionId, geometry: $geometry, displayScale: $displayScale,
          blockState: $blockState, producerWrite: $producer[0],
          finalDraw: ($draw[0] + {available: true})}'
else
    jq -n --arg backend "$BACKEND" --arg workload "$WORKLOAD" --argjson geometry "$geometry" \
        --argjson displayScale "$display_scale" \
        --slurpfile producer "$PRODUCER_RESULT" \
        '{schemaVersion: 1, backend: $backend, workload: $workload, geometry: $geometry, displayScale: $displayScale, producerWrite: $producer[0], finalDraw: {available: false, reason: "unavailable-for-ghostty-backend"}}'
fi
echo "Benchmark diagnostics: $ARTIFACTS" >&2
