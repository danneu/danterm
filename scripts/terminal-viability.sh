#!/usr/bin/env bash
# Opt-in end-to-end viability gate for the interactive Swift terminal engine slice.
set -euo pipefail

VIABILITY_BUNDLE_ID="com.danneu.danterm-terminal-viability"
VIABILITY_APP_NAME="DanTerm Terminal Viability"
VIABILITY_NARROW_COLUMNS=56
VIABILITY_WIDE_COLUMNS=90
VIABILITY_ROWS=25
VIABILITY_TIMEOUT_SECONDS=25
VIABILITY_IDLE_SECONDS=2
VIABILITY_IDLE_CPU_LIMIT_SECONDS=0.08

extract_marker_region() {
    local input="$1"
    local begin="$2"
    local end="$3"
    local output="$4"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin {
            if (active || found) exit 2
            active = 1
            found = 1
        }
        active { print }
        active && $0 == end { active = 0; complete = 1 }
        END { if (!found || active || !complete) exit 3 }
    ' "$input" >"$output"
}

assert_hidden_trace() {
    local event_log="$1"
    local pane_id="$2"
    awk -v hidden="session.visibilityChanged:$pane_id:false" \
        -v visible="session.visibilityChanged:$pane_id:true" '
        $0 == hidden { state = 1; next }
        state == 1 && $0 == "session.planDelivered" { exit 2 }
        state == 1 && $0 == visible { state = 2; next }
        state == 2 && $0 == "session.planDelivered" { proved = 1; exit 0 }
        END { if (!proved) exit 3 }
    ' "$event_log"
}

account_shell() {
    dscacheutil -q user -a name "$(id -un)" \
        | awk '$1 == "shell:" { print $2; exit }'
}

current_input_source() {
    defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID 2>/dev/null || true
}

current_modifier_flags() {
    osascript -l JavaScript -e \
        'ObjC.import("CoreGraphics"); $.CGEventSourceFlagsState($.kCGEventSourceStateHIDSystemState).toString()' \
        2>/dev/null || true
}

terminate_owned_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _attempt in $(seq 1 40); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

make_short_runtime_alias() {
    local target="$1"
    local alias_path
    alias_path="$(mktemp -d /private/tmp/dtv.XXXXXX)"
    rmdir "$alias_path"
    ln -s "$target" "$alias_path"
    printf '%s\n' "$alias_path"
}

assert_unix_socket_path_fits() {
    local path="$1"
    local byte_count
    byte_count="$(LC_ALL=C printf '%s' "$path" | wc -c | tr -d ' ')"
    (( byte_count < 104 ))
}

assemble_viability_bundle() {
    local app_path="$1"
    local layout_plan="$2"
    local repo_root="$3"
    local layout_tool="$4"
    local app_product="$5"
    local cli_product="$6"
    local bootstrap_product="$7"

    "$layout_tool" viability >"$layout_plan" || return
    assemble-app-bundle.sh "$app_path" "$layout_plan" "$repo_root" \
        --product "DanTerm=$app_product" \
        --product "DanTermCLI=$cli_product" \
        --product "PTYSessionBootstrap=$bootstrap_product" || return
    sign-app-bundle.sh "$app_path" "$layout_plan" "$repo_root" - >/dev/null
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

if [[ "${DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL:-}" != "1" ]]; then
    echo "Refusing to build or control an app without DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1" >&2
    exit 2
fi

for command in awk codesign defaults dscacheutil id jq less osascript pgrep pmset ps swift xcrun; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 1
    }
done

ACCOUNT_SHELL="$(account_shell)"
if [[ "$ACCOUNT_SHELL" != "/bin/zsh" ]]; then
    echo "Terminal viability requires a zsh account shell; found ${ACCOUNT_SHELL:-none}." >&2
    exit 1
fi

INPUT_SOURCE="$(current_input_source)"
case "$INPUT_SOURCE" in
    com.apple.keylayout.US|com.apple.keylayout.ABC) ;;
    *)
        echo "Terminal viability requires a U.S./ABC input source; found ${INPUT_SOURCE:-none}." >&2
        exit 1
        ;;
esac

MODIFIER_FLAGS="$(current_modifier_flags)"
if [[ ! "$MODIFIER_FLAGS" =~ ^[0-9]+$ ]]; then
    echo "Terminal viability could not read the current keyboard modifier state." >&2
    exit 1
fi
if (( MODIFIER_FLAGS & 65536 )); then
    echo "Caps Lock must be off for terminal viability's lowercase keyboard evidence." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTERNAL_FIXTURE="$REPO_ROOT/lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm/state-movecursor.json"
EXTERNAL_COLUMNS="$(jq -er '.initial.columns' "$EXTERNAL_FIXTURE")"
EXTERNAL_ROWS="$(jq -er '.initial.rows' "$EXTERNAL_FIXTURE")"
BUILD_PATH="$REPO_ROOT/.build/terminal-viability-swiftpm"
RUNS_ROOT="$REPO_ROOT/.build/terminal-viability-runs"
RUN_ROOT="$RUNS_ROOT/$(date +%Y-%m-%d-%H%M%S)-$$"
mkdir -p "$RUN_ROOT"
RUNTIME_ROOT="$(make_short_runtime_alias "$RUN_ROOT")"
RUN_MARKER="$RUN_ROOT/.danterm-terminal-viability-run"
CAPTURE_DIRECTORY="$RUN_ROOT/artifacts"
RECORDING_DIRECTORY="$CAPTURE_DIRECTORY/recordings"
CORPUS_DIRECTORY="$RUN_ROOT/corpus"
ISOLATED_HOME="$RUNTIME_ROOT/home"
ISOLATED_TMP="$RUNTIME_ROOT/tmp"
ISOLATED_ZDOTDIR="$RUNTIME_ROOT/zdotdir"
APP_PATH="$RUN_ROOT/$VIABILITY_APP_NAME.app"
APP_LOG="$CAPTURE_DIRECTORY/app.log"
PATH_PROBE="$CAPTURE_DIRECTORY/path-probe.json"
EVENT_LOG="$CAPTURE_DIRECTORY/terminal-events.log"
APP_PID=""
APP_DESCENDANTS_FILE="$CAPTURE_DIRECTORY/app-descendants.txt"

mkdir -p "$CAPTURE_DIRECTORY" "$RECORDING_DIRECTORY" "$CORPUS_DIRECTORY" \
    "$ISOLATED_HOME" "$ISOLATED_TMP" "$ISOLATED_ZDOTDIR"
touch "$RUN_MARKER"

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    terminate_owned_pid "$APP_PID"
    if [[ -L "$RUNTIME_ROOT" ]]; then
        unlink "$RUNTIME_ROOT"
    fi
    printf '%s\n' "$status" >"$CAPTURE_DIRECTORY/exit-status.txt"
    if [[ $status -eq 0 ]]; then
        echo "Terminal viability artifacts: $CAPTURE_DIRECTORY"
    else
        echo "Terminal viability failed; artifacts preserved at: $CAPTURE_DIRECTORY" >&2
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

assert_unix_socket_path_fits \
    "$ISOLATED_HOME/Library/Caches/$VIABILITY_BUNDLE_ID/control.sock" || {
    echo "Terminal viability runtime root exceeds the Unix socket path budget." >&2
    exit 1
}

cat >"$ISOLATED_ZDOTDIR/.zshenv" <<'EOF'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export HISTFILE=/dev/null
unset ZSH_TMUX_AUTOSTART
EOF
cat >"$ISOLATED_ZDOTDIR/.zprofile" <<'EOF'
:
EOF
cat >"$ISOLATED_ZDOTDIR/.zshrc" <<'EOF'
setopt no_beep
unsetopt share_history
PROMPT='DANTERM-VIABILITY> '
RPROMPT=''
EOF

cat >"$CORPUS_DIRECTORY/unicode.txt" <<'EOF'
CORPUS-UNICODE-BEGIN
SPANISH: niño, acción, corazón
CHINESE: 你好世界
EMOJI: 🙂 🚀
CORPUS-UNICODE-END
EOF
{
    echo "LESS-BEGIN"
    for line in $(seq -w 1 80); do
        echo "LESS-LINE-$line: controlled pager content"
    done
    echo "LESS-END"
} >"$CORPUS_DIRECTORY/pager.txt"

cat >"$CORPUS_DIRECTORY/external-replay.py" <<'PYTHON'
#!/usr/bin/env python3
import base64
import json
import os
import signal
import sys

fixture_path, ready_path, stop_path = sys.argv[1:]
signal.signal(signal.SIGUSR1, lambda _signal, _frame: None)
with open(fixture_path, "r", encoding="utf-8") as stream:
    fixture = json.load(stream)
for event in fixture["events"]:
    if event["type"] != "feed":
        continue
    encodings = set(event).intersection({"base64", "text", "hex"})
    if encodings not in ({"base64"}, {"text"}):
        raise ValueError("Neutral feed must contain exactly one of base64 or text")
    if "text" in event:
        payload = event["text"].encode("utf-8")
    else:
        payload = base64.b64decode(event["base64"], validate=True)
    os.write(1, payload)
with open(ready_path, "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while not os.path.exists(stop_path):
    signal.pause()
PYTHON
chmod +x "$CORPUS_DIRECTORY/external-replay.py"

echo "Building isolated Swift-engine viability app..."
swift build \
    --package-path "$REPO_ROOT" \
    --build-path "$BUILD_PATH" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION
BIN_PATH="$(swift build \
    --package-path "$REPO_ROOT" \
    --build-path "$BUILD_PATH" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION \
    --show-bin-path)"
swift build \
    --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$BUILD_PATH/TerminalPTY" \
    --product PTYSessionBootstrap
BOOTSTRAP_BIN_PATH="$(swift build \
    --package-path "$REPO_ROOT/lib/TerminalPTY" \
    --build-path "$BUILD_PATH/TerminalPTY" \
    --show-bin-path)"

# The replay helper is a product of lib/TerminalCore, so SwiftPM links it and the gate
# compiles it. It was once a loose .swift file here, hand-linked against TerminalCore's
# scraped object files -- a shape that builds nothing until this harness runs, which is
# how the headless draw arm went days without a compiler noticing it had rotted.
# DANTERM_TERMINAL_CHARACTERIZATION is an app/ define; no TerminalCore source reads it,
# so building from the package rather than the root bin path changes nothing here.
swift build \
    --package-path "$REPO_ROOT/lib/TerminalCore" \
    --build-path "$BUILD_PATH/TerminalCore" \
    --product TerminalRecordingReplay
REPLAY_BIN="$(swift build \
    --package-path "$REPO_ROOT/lib/TerminalCore" \
    --build-path "$BUILD_PATH/TerminalCore" \
    --show-bin-path)/TerminalRecordingReplay"
cp "$REPLAY_BIN" "$RUN_ROOT/terminal-recording-replay"

LAYOUT_PLAN="$RUN_ROOT/bundle-layout.json"
PATH="$PATH:$SCRIPT_DIR" assemble_viability_bundle \
    "$APP_PATH" "$LAYOUT_PLAN" "$REPO_ROOT" "$BIN_PATH/DanTermBundleLayoutTool" \
    "$BIN_PATH/DanTerm" "$BIN_PATH/DanTermCLI" \
    "$BOOTSTRAP_BIN_PATH/PTYSessionBootstrap"

echo "Launching $VIABILITY_APP_NAME in $RUN_ROOT..."
env \
    HOME="$ISOLATED_HOME" \
    CFFIXED_USER_HOME="$ISOLATED_HOME" \
    TMPDIR="$ISOLATED_TMP/" \
    ZDOTDIR="$ISOLATED_ZDOTDIR" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DANTERM_PTY_RECORDING_DIR="$RECORDING_DIRECTORY" \
    DANTERM_TERMINAL_CHARACTERIZATION_PATH_PROBE="$PATH_PROBE" \
    DANTERM_TERMINAL_CHARACTERIZATION_TEMP_ROOT="$ISOLATED_TMP" \
    DANTERM_TERMINAL_CHARACTERIZATION_EVENT_LOG="$EVENT_LOG" \
    "$APP_PATH/Contents/MacOS/$VIABILITY_APP_NAME" \
    >"$APP_LOG" 2>&1 &
APP_PID=$!

wait_for_file() {
    local path="$1"
    local description="$2"
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    while [[ ! -f "$path" ]]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "$VIABILITY_APP_NAME exited while waiting for $description" >&2
            return 1
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for $description" >&2
            return 1
        fi
        sleep 0.05
    done
}

path_is_within() {
    local root="$1"
    local candidate="$2"
    local resolved_root resolved_candidate
    resolved_root="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root")"
    resolved_candidate="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate")"
    [[ "$resolved_candidate" == "$resolved_root" || "$resolved_candidate" == "$resolved_root/"* ]]
}

assert_probe_paths() {
    local key value
    for key in home applicationSupport caches temporary config recovery socket replay; do
        value="$(jq -er --arg key "$key" '.[$key]' "$PATH_PROBE")" || return 1
        path_is_within "$RUN_ROOT" "$value" || {
            echo "Viability path escaped run-owned root: $key=$value" >&2
            return 1
        }
    done
}

wait_for_file "$PATH_PROBE" "the app path probe"
assert_probe_paths
SOCKET_PATH="$(jq -r '.socket' "$PATH_PROBE")"
RECOVERY_PATH="$(jq -r '.recovery' "$PATH_PROBE")"
CLI="$APP_PATH/Contents/Helpers/danterm"
export DANTERM=1
export DANTERM_SOCK="$SOCKET_PATH"

wait_for_pane() {
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    local model
    while true; do
        if model="$("$CLI" ls 2>"$CAPTURE_DIRECTORY/last-cli-error.txt")"; then
            printf '%s\n' "$model" >"$CAPTURE_DIRECTORY/last-model.json"
            PANE_ID="$(printf '%s\n' "$model" | jq -er \
                '.selectedTabId as $tab | .groups[].tabs[] | select(.id == $tab) | .focusedPaneId // empty' \
                2>/dev/null || true)"
            [[ -n "$PANE_ID" ]] && return 0
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for the Swift terminal pane" >&2
            return 1
        fi
        sleep 0.05
    done
}
wait_for_pane
PRIMARY_PANE_ID="$PANE_ID"
PRIMARY_GROUP_ID="$(jq -er \
    '.selectedTabId as $tab | .groups[] | select(any(.tabs[]; .id == $tab)) | .id' \
    "$CAPTURE_DIRECTORY/last-model.json")"
PRIMARY_EVENT_ID="$(printf '%s' "$PRIMARY_PANE_ID" | tr '[:lower:]' '[:upper:]')"

wait_for_pane_marker() {
    local pane_id="$1"
    local marker="$2"
    local match_mode="${3:-exact}"
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    local probe="$RUN_ROOT/pane-marker-probe"
    while true; do
        if "$CLI" pane read --pane "$pane_id" --lines 400 >"$probe" 2>/dev/null; then
            if [[ "$match_mode" == "substring" ]] && grep -qF "$marker" "$probe"; then
                return 0
            fi
            if [[ "$match_mode" == "exact" ]] && grep -qxF "$marker" "$probe"; then
                return 0
            fi
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for pane marker: $marker" >&2
            return 1
        fi
        sleep 0.05
    done
}

wait_for_pane_absent() {
    local pane_id="$1"
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    while "$CLI" pane info --pane "$pane_id" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for exited pane: $pane_id" >&2
            return 1
        fi
        sleep 0.05
    done
}

wait_for_recording_count() {
    local expected="$1"
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    local count
    while true; do
        count="$(find "$RECORDING_DIRECTORY" -name 'pane-*.json' -type f | wc -l | tr -d ' ')"
        [[ "$count" -eq "$expected" ]] && return 0
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for $expected terminal recordings; found $count" >&2
            return 1
        fi
        sleep 0.05
    done
}

send_command_and_wait() {
    local pane_id="$1"
    local command="$2"
    local marker="$3"
    "$CLI" pane input --pane "$pane_id" --literal -- "$command"
    "$CLI" pane input --pane "$pane_id" -- Enter
    wait_for_pane_marker "$pane_id" "$marker"
}

wait_for_process_command() {
    local pid="$1"
    local expected="$2"
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    local command
    while true; do
        command="$(ps -p "$pid" -o comm= 2>/dev/null | xargs)"
        [[ "$command" == "$expected" ]] && return 0
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for process $pid to become $expected; found ${command:-none}." >&2
            return 1
        fi
        sleep 0.05
    done
}

assert_process_descends_from() {
    local pid="$1"
    local ancestor="$2"
    local parent
    while [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 1 ]]; do
        [[ "$pid" -eq "$ancestor" ]] && return 0
        parent="$(ps -p "$pid" -o ppid= 2>/dev/null | xargs)"
        [[ "$parent" =~ ^[0-9]+$ ]] || return 1
        pid="$parent"
    done
    return 1
}

window_size() {
    osascript - "$APP_PID" <<'APPLESCRIPT'
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        set currentSize to size of window 1 of targetProcess
        return ((item 1 of currentSize) as text) & " " & ((item 2 of currentSize) as text)
    end tell
end run
APPLESCRIPT
}

set_window_size() {
    local width="$1"
    local height="$2"
    osascript - "$APP_PID" "$width" "$height" <<'APPLESCRIPT' >/dev/null
on run argv
    set targetPid to (item 1 of argv) as integer
    set targetWidth to (item 2 of argv) as integer
    set targetHeight to (item 3 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        set size of window 1 of targetProcess to {targetWidth, targetHeight}
    end tell
end run
APPLESCRIPT
}

GRID_SAMPLE=0
sample_grid() {
    local pane_id="$1"
    GRID_SAMPLE=$((GRID_SAMPLE + 1))
    local marker="GRID-$GRID_SAMPLE:"
    "$CLI" pane input --pane "$pane_id" --literal -- "printf '$marker%s\\n' \"\$(stty size)\""
    "$CLI" pane input --pane "$pane_id" -- Enter
    local deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
    local dimensions=""
    while [[ -z "$dimensions" ]]; do
        "$CLI" pane read --pane "$pane_id" --lines 40 >"$RUN_ROOT/grid-probe.txt"
        dimensions="$(grep -oE "${marker}[0-9]+ [0-9]+" "$RUN_ROOT/grid-probe.txt" | tail -1)"
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for PTY grid sample." >&2
            return 1
        fi
        [[ -n "$dimensions" ]] || sleep 0.05
    done
    [[ -n "$dimensions" ]] || return 1
    read -r OBSERVED_ROWS OBSERVED_COLUMNS <<<"${dimensions#"$marker"}"
    [[ "$OBSERVED_ROWS" =~ ^[0-9]+$ && "$OBSERVED_COLUMNS" =~ ^[0-9]+$ ]]
}

resize_to_grid() {
    local pane_id="$1"
    local target_columns="$2"
    local target_rows="$3"
    local current_width current_height next_width next_height
    for _attempt in $(seq 1 35); do
        sample_grid "$pane_id"
        if [[ "$OBSERVED_COLUMNS" -eq "$target_columns" && "$OBSERVED_ROWS" -eq "$target_rows" ]]; then
            return 0
        fi
        read -r current_width current_height <<<"$(window_size)"
        next_width=$((current_width + (target_columns - OBSERVED_COLUMNS) * 7))
        next_height=$((current_height + (target_rows - OBSERVED_ROWS) * 15))
        (( next_width < 600 )) && next_width=600
        (( next_height < 320 )) && next_height=320
        set_window_size "$next_width" "$next_height"
    done
    sample_grid "$pane_id"
    echo "Could not reach PTY grid ${target_columns}x${target_rows}; observed ${OBSERVED_COLUMNS}x${OBSERVED_ROWS}." >&2
    echo "Grant Accessibility permission to the current terminal and retry." >&2
    return 1
}

capture_region() {
    local pane_id="$1"
    local output="$2"
    local full="$RUN_ROOT/full-history.txt"
    "$CLI" pane read --pane "$pane_id" --lines 400 >"$full"
    extract_marker_region "$full" REFLOW-BEGIN REFLOW-END "$output"
}

wait_for_pane_marker "$PRIMARY_PANE_ID" "DANTERM-VIABILITY>" substring
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- C-c
wait_for_pane_marker "$PRIMARY_PANE_ID" "DANTERM-VIABILITY>" substring

osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        set frontmost of targetProcess to true
        tell targetProcess
            keystroke "echo TYPED:ordinary"
            key code 36
            keystroke "echo DEADKEY:"
            key code 14 using option down
            key code 14
            key code 36
        end tell
    end tell
end run
APPLESCRIPT
wait_for_pane_marker "$PRIMARY_PANE_ID" "TYPED:ordinary"
wait_for_pane_marker "$PRIMARY_PANE_ID" "DEADKEY:é"

send_command_and_wait "$PRIMARY_PANE_ID" \
    "printf '%s\\n' 'SPANISH: niño, acción, corazón' 'CHINESE: 你好世界' 'EMOJI: 🙂 🚀'" \
    "EMOJI: 🙂 🚀"
wait_for_pane_marker "$PRIMARY_PANE_ID" "SPANISH: niño, acción, corazón"
wait_for_pane_marker "$PRIMARY_PANE_ID" "CHINESE: 你好世界"

"$CLI" pane input --pane "$PRIMARY_PANE_ID" --literal -- "printf 'EDIT:righX\\n'"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Left Left Left Backspace
"$CLI" pane input --pane "$PRIMARY_PANE_ID" --literal -- t
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Enter
wait_for_pane_marker "$PRIMARY_PANE_ID" "EDIT:right"

FOREGROUND_PID_FILE="$RUN_ROOT/foreground-sleep.pid"
printf -v foreground_pid_argument '%q' "$FOREGROUND_PID_FILE"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" --literal -- \
    "/bin/sh -c 'echo \$\$ > $foreground_pid_argument; exec /bin/sleep 30'"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Enter
wait_for_file "$FOREGROUND_PID_FILE" "the foreground sleep PID"
FOREGROUND_SLEEP_PID="$(cat "$FOREGROUND_PID_FILE")"
[[ "$FOREGROUND_SLEEP_PID" =~ ^[0-9]+$ ]] || {
    echo "Foreground sleep wrote an invalid PID: $FOREGROUND_SLEEP_PID" >&2
    exit 1
}
wait_for_process_command "$FOREGROUND_SLEEP_PID" "/bin/sleep"
assert_process_descends_from "$FOREGROUND_SLEEP_PID" "$APP_PID" || {
    echo "Foreground sleep was not a descendant of the viability app." >&2
    exit 1
}
ps -p "$FOREGROUND_SLEEP_PID" -o pid=,ppid=,pgid=,comm=,command= \
    >"$CAPTURE_DIRECTORY/foreground-process.txt"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- C-c
send_command_and_wait "$PRIMARY_PANE_ID" "echo JOB-CTRL-C" "JOB-CTRL-C"
send_command_and_wait "$PRIMARY_PANE_ID" \
    "sleep 1 & wait; echo JOB-BACKGROUND-DONE" "JOB-BACKGROUND-DONE"

send_command_and_wait "$PRIMARY_PANE_ID" \
    "cd '$CORPUS_DIRECTORY' && ls -1; echo LS-DONE" "LS-DONE"
wait_for_pane_marker "$PRIMARY_PANE_ID" "external-replay.py"
wait_for_pane_marker "$PRIMARY_PANE_ID" "pager.txt"
wait_for_pane_marker "$PRIMARY_PANE_ID" "unicode.txt"
send_command_and_wait "$PRIMARY_PANE_ID" \
    "cat '$CORPUS_DIRECTORY/unicode.txt'; echo CAT-DONE" "CAT-DONE"
wait_for_pane_marker "$PRIMARY_PANE_ID" "CORPUS-UNICODE-END"

"$CLI" pane input --pane "$PRIMARY_PANE_ID" --literal -- \
    "less '$CORPUS_DIRECTORY/pager.txt'"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Enter
wait_for_pane_marker "$PRIMARY_PANE_ID" "LESS-BEGIN"
for _page in 1 2 3 4; do
    "$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Space
done
wait_for_pane_marker "$PRIMARY_PANE_ID" "LESS-END"
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- q
send_command_and_wait "$PRIMARY_PANE_ID" "echo LESS-QUIT-DONE" "LESS-QUIT-DONE"

resize_to_grid "$PRIMARY_PANE_ID" "$VIABILITY_NARROW_COLUMNS" "$VIABILITY_ROWS"
send_command_and_wait "$PRIMARY_PANE_ID" \
    "printf '%s\\n' REFLOW-BEGIN 'LONG-LOGICAL:abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789-end' HARD-BREAK-A HARD-BREAK-B REFLOW-END" \
    "REFLOW-END"
capture_region "$PRIMARY_PANE_ID" "$CAPTURE_DIRECTORY/reflow-narrow.txt"
resize_to_grid "$PRIMARY_PANE_ID" "$VIABILITY_WIDE_COLUMNS" "$VIABILITY_ROWS"
capture_region "$PRIMARY_PANE_ID" "$CAPTURE_DIRECTORY/reflow-wide.txt"
resize_to_grid "$PRIMARY_PANE_ID" "$VIABILITY_NARROW_COLUMNS" "$VIABILITY_ROWS"
capture_region "$PRIMARY_PANE_ID" "$CAPTURE_DIRECTORY/reflow-narrow-again.txt"
cmp -s "$CAPTURE_DIRECTORY/reflow-narrow.txt" "$CAPTURE_DIRECTORY/reflow-wide.txt" \
    || { echo "Marker-bounded history changed after widening." >&2; exit 1; }
cmp -s "$CAPTURE_DIRECTORY/reflow-narrow.txt" "$CAPTURE_DIRECTORY/reflow-narrow-again.txt" \
    || { echo "Marker-bounded history changed after narrowing again." >&2; exit 1; }

SECOND_TAB_JSON="$("$CLI" tab new --group "$PRIMARY_GROUP_ID" --foreground)"
SECOND_PANE_ID="$(printf '%s\n' "$SECOND_TAB_JSON" | jq -er '.tab.focusedPaneId')"
wait_for_pane_marker "$SECOND_PANE_ID" "DANTERM-VIABILITY>" substring
hidden_event="session.visibilityChanged:$PRIMARY_EVENT_ID:false"
hidden_event_line="$(grep -nF "$hidden_event" "$EVENT_LOG" | tail -1 | cut -d: -f1)"
[[ "$hidden_event_line" =~ ^[0-9]+$ ]] || {
    echo "Primary pane never recorded its hidden transition." >&2
    exit 1
}
hidden_start_line="$(wc -l <"$EVENT_LOG" | tr -d ' ')"
sed -n "${hidden_event_line}p" "$EVENT_LOG" >"$CAPTURE_DIRECTORY/hidden-trace.log"
send_command_and_wait "$PRIMARY_PANE_ID" "echo HIDDEN-PANE-OUTPUT" "HIDDEN-PANE-OUTPUT"
"$CLI" pane focus --pane "$PRIMARY_PANE_ID"
wait_for_pane_marker "$PRIMARY_PANE_ID" "HIDDEN-PANE-OUTPUT"
tail -n "+$((hidden_start_line + 1))" "$EVENT_LOG" \
    >>"$CAPTURE_DIRECTORY/hidden-trace.log"
assert_hidden_trace "$CAPTURE_DIRECTORY/hidden-trace.log" "$PRIMARY_EVENT_ID" || {
    echo "Hidden/reveal trace violated event-ordered planning invariants." >&2
    exit 1
}

idle_start_line="$(wc -l <"$EVENT_LOG" | tr -d ' ')"
cpu_before="$(ps -p "$APP_PID" -o cputime= | xargs)"
/usr/bin/python3 - "$VIABILITY_IDLE_SECONDS" "$APP_PID" <<'PYTHON'
import os
import sys
import time

duration = float(sys.argv[1])
pid = int(sys.argv[2])
deadline = time.monotonic() + duration
while time.monotonic() < deadline:
    os.kill(pid, 0)
    time.sleep(0.05)
PYTHON
cpu_after="$(ps -p "$APP_PID" -o cputime= | xargs)"
/usr/bin/python3 - "$cpu_before" "$cpu_after" "$VIABILITY_IDLE_CPU_LIMIT_SECONDS" \
    >"$CAPTURE_DIRECTORY/idle-cpu.txt" <<'PYTHON'
import sys

def seconds(value):
    fields = value.split(":")
    total = 0.0
    for field in fields:
        total = total * 60 + float(field)
    return total

before, after, limit = sys.argv[1:]
delta = seconds(after) - seconds(before)
print(f"before={before} after={after} delta={delta:.2f} limit={float(limit):.2f}")
if delta > float(limit):
    raise SystemExit(1)
PYTHON
tail -n "+$((idle_start_line + 1))" "$EVENT_LOG" >"$CAPTURE_DIRECTORY/idle-events.log"
if grep -qxF "session.planDelivered" "$CAPTURE_DIRECTORY/idle-events.log"; then
    echo "Idle window delivered a render plan." >&2
    exit 1
fi
pmset -g assertions >"$CAPTURE_DIRECTORY/power-assertions.txt"
if grep -Eq "pid[[:space:]]+$APP_PID\\(" "$CAPTURE_DIRECTORY/power-assertions.txt"; then
    echo "DanTerm held a power assertion during the idle window." >&2
    exit 1
fi

"$CLI" pane focus --pane "$SECOND_PANE_ID"
resize_to_grid "$SECOND_PANE_ID" "$EXTERNAL_COLUMNS" "$EXTERNAL_ROWS"
"$RUN_ROOT/terminal-recording-replay" screen "$EXTERNAL_FIXTURE" \
    >"$CAPTURE_DIRECTORY/external-headless-screen.txt"
EXTERNAL_READY="$RUN_ROOT/external-ready"
EXTERNAL_STOP="$RUN_ROOT/external-stop"
"$CLI" pane input --pane "$SECOND_PANE_ID" --literal -- \
    "exec /usr/bin/python3 '$CORPUS_DIRECTORY/external-replay.py' '$EXTERNAL_FIXTURE' '$EXTERNAL_READY' '$EXTERNAL_STOP'"
"$CLI" pane input --pane "$SECOND_PANE_ID" -- Enter
wait_for_file "$EXTERNAL_READY" "the live external fixture replay"
external_deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
while true; do
    "$CLI" pane read --pane "$SECOND_PANE_ID" >"$CAPTURE_DIRECTORY/external-live-screen.txt"
    if cmp -s "$CAPTURE_DIRECTORY/external-headless-screen.txt" \
        "$CAPTURE_DIRECTORY/external-live-screen.txt"; then
        break
    fi
    if (( SECONDS >= external_deadline )); then
        echo "Live pane text did not match headless replay of the selected external fixture." >&2
        exit 1
    fi
    sleep 0.05
done
touch "$EXTERNAL_STOP"
kill -USR1 "$(cat "$EXTERNAL_READY")" 2>/dev/null || true
wait_for_pane_absent "$SECOND_PANE_ID"
wait_for_recording_count 1
kill -0 "$APP_PID"

"$CLI" pane focus --pane "$PRIMARY_PANE_ID"
send_command_and_wait "$PRIMARY_PANE_ID" "echo VIABILITY-FINAL" "VIABILITY-FINAL"

collect_descendants() {
    local parent="$1"
    local child
    while read -r child; do
        [[ -n "$child" ]] || continue
        echo "$child"
        collect_descendants "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
}
collect_descendants "$APP_PID" | sort -u >"$APP_DESCENDANTS_FILE"

"$CLI" pane input --pane "$PRIMARY_PANE_ID" --literal -- exit
"$CLI" pane input --pane "$PRIMARY_PANE_ID" -- Enter
wait_for_recording_count 2

quit_deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
while true; do
    if osascript - "$APP_PID" <<'APPLESCRIPT' 2>/dev/null | grep -qx true; then
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        return exists window "Quit DanTerm?" of targetProcess
    end tell
end run
APPLESCRIPT
        break
    fi
    if (( SECONDS >= quit_deadline )); then
        echo "Timed out waiting for last-pane quit confirmation." >&2
        exit 1
    fi
    sleep 0.05
done

osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        click button "Quit" of window "Quit DanTerm?" of targetProcess
    end tell
end run
APPLESCRIPT

quit_deadline=$((SECONDS + VIABILITY_TIMEOUT_SECONDS))
while kill -0 "$APP_PID" 2>/dev/null; do
    if (( SECONDS >= quit_deadline )); then
        echo "Timed out waiting for normal app termination." >&2
        exit 1
    fi
    sleep 0.05
done
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

[[ ! -e "$SOCKET_PATH" ]] || {
    echo "Control socket remained after clean termination: $SOCKET_PATH" >&2
    exit 1
}
[[ ! -e "$RECOVERY_PATH/session.json" ]] || {
    echo "Session lock remained after clean termination: $RECOVERY_PATH/session.json" >&2
    exit 1
}
while read -r descendant; do
    [[ -n "$descendant" ]] || continue
    if kill -0 "$descendant" 2>/dev/null; then
        echo "App descendant remained after clean termination: $descendant" >&2
        exit 1
    fi
done <"$APP_DESCENDANTS_FILE"

external_recordings=0
primary_recordings=0
for recording in "$RECORDING_DIRECTORY"/pane-*.json; do
    jq -e \
        '.version == 1 and .provenance.source == "danterm" and .provenance.test == "milestone-4-viability" and ([.events[].type] | all(. == "feed" or . == "write" or . == "resize"))' \
        "$recording" >/dev/null
    replay_base="$CAPTURE_DIRECTORY/$(basename "$recording" .json)"
    "$RUN_ROOT/terminal-recording-replay" screen "$recording" >"$replay_base-screen.txt"
    "$RUN_ROOT/terminal-recording-replay" history "$recording" >"$replay_base-history.txt"
    if cmp -s "$replay_base-screen.txt" "$CAPTURE_DIRECTORY/external-headless-screen.txt"; then
        external_recordings=$((external_recordings + 1))
    fi
    if grep -qF "VIABILITY-FINAL" "$replay_base-history.txt"; then
        primary_recordings=$((primary_recordings + 1))
    fi
done
[[ "$external_recordings" -eq 1 && "$primary_recordings" -eq 1 ]] || {
    echo "Recordings did not correspond exactly to the two child-ended panes." >&2
    exit 1
}

cat >"$CAPTURE_DIRECTORY/summary.txt" <<EOF
result=pass
backend=swift
account_shell=$ACCOUNT_SHELL
input_source=$INPUT_SOURCE
locale=en_US.UTF-8
reflow=${VIABILITY_NARROW_COLUMNS}x${VIABILITY_ROWS}->${VIABILITY_WIDE_COLUMNS}x${VIABILITY_ROWS}->${VIABILITY_NARROW_COLUMNS}x${VIABILITY_ROWS}
external_fixture=$(basename "$EXTERNAL_FIXTURE")
external_grid=${EXTERNAL_COLUMNS}x${EXTERNAL_ROWS}
recordings=2
EOF

echo "Terminal viability passed."
