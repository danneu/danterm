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

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

WORKLOAD="${1:-scrollback-stream}"
BACKEND="${2:-swift}"
BACKEND="${BACKEND#backend=}"
MODE="${DANTERM_BENCHMARK_MODE:-measure}"
PROFILE_IDENTITY_PATH="${DANTERM_BENCHMARK_IDENTITY_PATH:-}"
TARGET_COLUMNS="${DANTERM_TERMINAL_BENCHMARK_COLUMNS:-80}"
TARGET_ROWS="${DANTERM_TERMINAL_BENCHMARK_ROWS:-24}"
LOCALIZED_UPDATES="${DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES:-0}"
CORPUS_PATH="$(cd "$(dirname "$0")/.." && pwd)/benchmarks/fixtures/terminal-app.json"
case "$BACKEND" in
    swift|ghostty) ;;
    *) echo "Unknown backend: $BACKEND (expected swift or ghostty)" >&2; exit 2 ;;
esac
case "$MODE" in
    measure|loop) ;;
    *) echo "Unknown benchmark mode: $MODE" >&2; exit 2 ;;
esac
if [[ "$MODE" == "loop" && -z "$PROFILE_IDENTITY_PATH" ]]; then
    echo "Sustained benchmark mode requires DANTERM_BENCHMARK_IDENTITY_PATH" >&2
    exit 2
fi
if [[ ! "$TARGET_COLUMNS" =~ ^[1-9][0-9]*$ || ! "$TARGET_ROWS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Benchmark geometry must use positive integer columns and rows" >&2
    exit 2
fi

for command in codesign jq plutil swift; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
[[ "$WORKLOAD" == "localized-draw-acceptance" ]] || jq -e --arg workload "$WORKLOAD" '.workloads[$workload] != null' "$CORPUS_PATH" >/dev/null || {
    echo "Unknown workload: $WORKLOAD" >&2
    exit 2
}

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
PRODUCER_RESULT="$ARTIFACTS/producer-write.json"
GEOMETRY_READY="$ARTIFACTS/geometry-ready"
PATH_PROBE="$ARTIFACTS/path-probe.json"
APP_LOG="$ARTIFACTS/app.log"
APP_PID=""
mkdir -p "$ARTIFACTS" "$HOME_DIR" "$TMP_DIR" "$ZDOTDIR"

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    terminate_owned_pid "$APP_PID"
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

swift build --package-path "$REPO_ROOT" --build-path "$BUILD_PATH" --configuration release \
    -Xswiftc -DDANTERM_TERMINAL_BENCHMARK >&2
BIN_PATH="$(swift build --package-path "$REPO_ROOT" --build-path "$BUILD_PATH" \
    --configuration release -Xswiftc -DDANTERM_TERMINAL_BENCHMARK --show-bin-path)"
swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --build-path "$BUILD_PATH/TerminalPTY" \
    --configuration release --product PTYSessionBootstrap >&2
BOOTSTRAP_BIN_PATH="$(swift build --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$BUILD_PATH/TerminalPTY" --configuration release --show-bin-path)"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources/ghostty"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm Benchmark"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
cp "$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap" "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
chmod +x "$APP_PATH/Contents/MacOS/DanTerm Benchmark" "$APP_PATH/Contents/Helpers/danterm" \
    "$APP_PATH/Contents/Helpers/PTYSessionBootstrap"
cp "$REPO_ROOT/app/Info.plist" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.danneu.danterm-terminal-benchmark.$$" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "DanTerm Benchmark" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "DanTerm Benchmark" "$APP_PATH/Contents/Info.plist"
plutil -remove CFBundleIconName "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
if [[ -d "$REPO_ROOT/lib/ghostty-themes" ]]; then
    cp -R "$REPO_ROOT/lib/ghostty-themes" "$APP_PATH/Contents/Resources/ghostty/themes"
else
    cp -R "$REPO_ROOT/.ghostty-src/zig-out/share/ghostty/themes" "$APP_PATH/Contents/Resources/ghostty/themes"
fi
codesign --force --deep --sign - --entitlements "$SCRIPT_DIR/terminal-benchmark-entitlements.plist" "$APP_PATH" >/dev/null
codesign -d --entitlements :- "$APP_PATH" 2>&1 | grep -q '<key>com.apple.security.get-task-allow</key>' || {
    echo "Benchmark app is missing the get-task-allow profiling entitlement" >&2
    exit 1
}

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
    DANTERM_TERMINAL_BENCHMARK_RESULT="$DRAW_RESULT" \
    DANTERM_TERMINAL_BENCHMARK_PRODUCER_RESULT="$PRODUCER_RESULT" \
    DANTERM_TERMINAL_BENCHMARK_GEOMETRY_READY="$GEOMETRY_READY" \
    DANTERM_TERMINAL_BENCHMARK_BACKEND="$BACKEND" \
    DANTERM_TERMINAL_BENCHMARK_WORKLOAD="$WORKLOAD" \
    DANTERM_TERMINAL_BENCHMARK_COLUMNS="$TARGET_COLUMNS" \
    DANTERM_TERMINAL_BENCHMARK_ROWS="$TARGET_ROWS" \
    DANTERM_BENCHMARK_MODE="$MODE" \
    "$APP_PATH/Contents/MacOS/DanTerm Benchmark" >"$APP_LOG" 2>&1 &
APP_PID=$!

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

printf -v command 'python3 %q' "$SCRIPT_DIR/terminal-benchmark-producer.py"
"$CLI" pane input --pane "$PANE_ID" --literal -- "$command"
"$CLI" pane input --pane "$PANE_ID" -- Enter
if [[ "$MODE" == "loop" ]]; then
    deadline=$((SECONDS + 20))
    while [[ ! -f "$GEOMETRY_READY" ]]; do
        if [[ -f "$PRODUCER_RESULT" ]]; then
            producer_error="$(jq -r '.error // empty' "$PRODUCER_RESULT")"
            [[ -z "$producer_error" ]] || { echo "$producer_error" >&2; exit 1; }
        fi
        (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark geometry" >&2; exit 1; }
        sleep 0.05
    done
    identity_tmp="$PROFILE_IDENTITY_PATH.tmp.$$"
    mkdir -p "$(dirname "$PROFILE_IDENTITY_PATH")"
    jq -n --argjson pid "$APP_PID" --arg workload "$WORKLOAD" --arg backend "$BACKEND" \
        --arg binary "$APP_PATH/Contents/MacOS/DanTerm Benchmark" --arg artifacts "$ARTIFACTS" \
        '{schemaVersion: 1, pid: $pid, workload: $workload, backend: $backend, binary: $binary, artifacts: $artifacts, profilingActive: true}' >"$identity_tmp"
    mv "$identity_tmp" "$PROFILE_IDENTITY_PATH"
    echo "Sustained benchmark identity: $PROFILE_IDENTITY_PATH" >&2
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.25; done
    wait "$APP_PID"
    exit $?
fi
deadline=$((SECONDS + 20))
while true; do
    if [[ -f "$PRODUCER_RESULT" ]]; then
        [[ -n "$(jq -r '.error // empty' "$PRODUCER_RESULT")" ]] && break
        [[ "$BACKEND" != "swift" || -f "$DRAW_RESULT" ]] && break
    fi
    (( SECONDS < deadline )) || { echo "Timed out waiting for benchmark metrics" >&2; exit 1; }
    sleep 0.05
done
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
    jq -n --arg backend "$BACKEND" --arg workload "$WORKLOAD" --argjson geometry "$geometry" \
        --argjson displayScale "$display_scale" \
        --slurpfile producer "$PRODUCER_RESULT" --slurpfile draw "$DRAW_RESULT" \
        '{schemaVersion: 1, backend: $backend, workload: $workload, geometry: $geometry, displayScale: $displayScale, producerWrite: $producer[0], finalDraw: ($draw[0] + {available: true})}'
else
    jq -n --arg backend "$BACKEND" --arg workload "$WORKLOAD" --argjson geometry "$geometry" \
        --argjson displayScale "$display_scale" \
        --slurpfile producer "$PRODUCER_RESULT" \
        '{schemaVersion: 1, backend: $backend, workload: $workload, geometry: $geometry, displayScale: $displayScale, producerWrite: $producer[0], finalDraw: {available: false, reason: "unavailable-for-ghostty-backend"}}'
fi
echo "Benchmark diagnostics: $ARTIFACTS" >&2
