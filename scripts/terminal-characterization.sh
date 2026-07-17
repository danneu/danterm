#!/usr/bin/env bash
# Opt-in real-Ghostty characterization of pane reads, reflow, and recovery text.
set -euo pipefail

CHARACTERIZATION_BUNDLE_ID="com.danneu.danterm-terminal-characterization"
CHARACTERIZATION_APP_NAME="DanTerm Terminal Characterization"
CHARACTERIZATION_NARROW_COLUMNS=56
CHARACTERIZATION_WIDE_COLUMNS=90
CHARACTERIZATION_TIMEOUT_SECONDS=20

path_is_within() {
    local root="$1"
    local candidate="$2"
    local resolved_root resolved_candidate
    resolved_root="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$root")" \
        || return 1
    resolved_candidate="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$candidate")" \
        || return 1
    [[ "$resolved_candidate" == "$resolved_root" || "$resolved_candidate" == "$resolved_root/"* ]]
}

assert_probe_paths() {
    local probe_file="$1"
    local owned_root="$2"
    local key value
    for key in home applicationSupport caches temporary config recovery socket replay; do
        value="$(jq -er --arg key "$key" '.[$key]' "$probe_file")" || return 1
        if ! path_is_within "$owned_root" "$value"; then
            echo "Characterization path escaped run-owned root: $key=$value" >&2
            return 1
        fi
    done

    local isolated_home application_support caches temporary config recovery socket replay
    isolated_home="$(jq -r '.home' "$probe_file")"
    application_support="$(jq -r '.applicationSupport' "$probe_file")"
    caches="$(jq -r '.caches' "$probe_file")"
    temporary="$(jq -r '.temporary' "$probe_file")"
    config="$(jq -r '.config' "$probe_file")"
    recovery="$(jq -r '.recovery' "$probe_file")"
    socket="$(jq -r '.socket' "$probe_file")"
    replay="$(jq -r '.replay' "$probe_file")"

    [[ "$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$isolated_home")" \
        == "$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$owned_root/home")" ]] \
        || return 1
    path_is_within "$isolated_home" "$application_support" || return 1
    path_is_within "$isolated_home" "$caches" || return 1
    path_is_within "$isolated_home" "$config" || return 1
    path_is_within "$application_support" "$recovery" || return 1
    path_is_within "$caches" "$socket" || return 1
    path_is_within "$temporary" "$replay" || return 1
}

assert_fixture() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    local failure_directory="$4"
    local preserved="$failure_directory/$label.actual"

    if [[ -f "$expected" ]] && cmp -s "$expected" "$actual"; then
        return 0
    fi

    mkdir -p "$(dirname "$preserved")"
    cp "$actual" "$preserved"
    echo "Characterization fixture mismatch: $label" >&2
    if [[ -f "$expected" ]]; then
        echo "Expected bytes (sed -n l):" >&2
        sed -n l "$expected" >&2
    else
        echo "Expected fixture is missing: $expected" >&2
    fi
    echo "Actual bytes (sed -n l):" >&2
    sed -n l "$actual" >&2
    echo "Preserved actual capture: $preserved" >&2
    return 1
}

terminate_owned_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    local attempt
    for attempt in $(seq 1 40); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

remove_owned_run_root() {
    local run_root="$1"
    local resolved_root resolved_parent
    [[ -d "$run_root" && -f "$run_root/.danterm-terminal-characterization-run" ]] || {
        echo "Refusing to remove unmarked characterization root: $run_root" >&2
        return 1
    }
    resolved_root="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$run_root")"
    resolved_parent="$(dirname "$resolved_root")"
    [[ "$resolved_root" != "/" && "$resolved_root" != "$resolved_parent" ]] || {
        echo "Refusing to remove broad characterization root: $resolved_root" >&2
        return 1
    }
    path_is_within "$resolved_parent" "$resolved_root" || return 1
    rm -rf "$resolved_root"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

if [[ "${DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL:-}" != "1" ]]; then
    echo "Refusing to build or control an app without DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$REPO_ROOT/fixtures/terminal-characterization/ghostty-inspection-recovery.json"
BUILD_PATH="$REPO_ROOT/.build/terminal-characterization-swiftpm"
FAILURE_ROOT="$REPO_ROOT/.build/terminal-characterization-failures"
RUN_ROOT="$(mktemp -d "/tmp/dtc.XXXXXX")"
RUN_MARKER="$RUN_ROOT/.danterm-terminal-characterization-run"
CAPTURE_DIRECTORY="$RUN_ROOT/captures"
STATE_DIRECTORY="$RUN_ROOT/child-state"
ISOLATED_HOME="$RUN_ROOT/home"
ISOLATED_TMP="$RUN_ROOT/tmp"
APP_PATH="$RUN_ROOT/$CHARACTERIZATION_APP_NAME.app"
APP_LOG="$RUN_ROOT/app.log"
PATH_PROBE="$RUN_ROOT/path-probe.json"
APP_PID=""
CHILD_PID=""
FAILURE_DIRECTORY=""
SUITE_SUCCEEDED=0

touch "$RUN_MARKER"
mkdir -p "$CAPTURE_DIRECTORY" "$STATE_DIRECTORY" "$ISOLATED_HOME" "$ISOLATED_TMP"

preserve_failure_artifacts() {
    [[ $SUITE_SUCCEEDED -eq 0 ]] || return 0
    [[ -d "$CAPTURE_DIRECTORY" ]] || return 0
    if [[ -z "$FAILURE_DIRECTORY" ]]; then
        FAILURE_DIRECTORY="$FAILURE_ROOT/$(date +%Y-%m-%d-%H%M%S)-$$"
    fi
    mkdir -p "$FAILURE_DIRECTORY"
    cp -R "$CAPTURE_DIRECTORY/." "$FAILURE_DIRECTORY/" 2>/dev/null || true
    cp "$APP_LOG" "$FAILURE_DIRECTORY/app.log" 2>/dev/null || true
    cp "$PATH_PROBE" "$FAILURE_DIRECTORY/path-probe.json" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    preserve_failure_artifacts
    terminate_owned_pid "$CHILD_PID"
    terminate_owned_pid "$APP_PID"
    remove_owned_run_root "$RUN_ROOT" || true
    if [[ $status -ne 0 && -n "$FAILURE_DIRECTORY" ]]; then
        echo "Characterization diagnostics: $FAILURE_DIRECTORY" >&2
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

for command in jq swift plutil codesign osascript; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 1
    }
done

if [[ ! -d "$REPO_ROOT/lib/GhosttyKit.xcframework" ]]; then
    echo "GhosttyKit.xcframework is missing; run ./build-lib.sh once." >&2
    exit 1
fi

echo "Building isolated characterization app..."
swift build \
    --package-path "$REPO_ROOT" \
    --build-path "$BUILD_PATH" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION
BIN_PATH="$(swift build \
    --package-path "$REPO_ROOT" \
    --build-path "$BUILD_PATH" \
    -Xswiftc -DDANTERM_TERMINAL_CHARACTERIZATION \
    --show-bin-path)"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources/ghostty"
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/$CHARACTERIZATION_APP_NAME"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/MacOS/$CHARACTERIZATION_APP_NAME" "$APP_PATH/Contents/Helpers/danterm"
cp "$REPO_ROOT/app/Info.plist" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$CHARACTERIZATION_BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "$CHARACTERIZATION_APP_NAME" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$CHARACTERIZATION_APP_NAME" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$CHARACTERIZATION_APP_NAME" "$APP_PATH/Contents/Info.plist"
plutil -remove CFBundleIconName "$APP_PATH/Contents/Info.plist" 2>/dev/null || true

if [[ -d "$REPO_ROOT/lib/ghostty-themes" ]]; then
    cp -R "$REPO_ROOT/lib/ghostty-themes" "$APP_PATH/Contents/Resources/ghostty/themes"
elif [[ -d "$REPO_ROOT/.ghostty-src/zig-out/share/ghostty/themes" ]]; then
    cp -R "$REPO_ROOT/.ghostty-src/zig-out/share/ghostty/themes" "$APP_PATH/Contents/Resources/ghostty/themes"
else
    echo "Ghostty themes are missing; run ./build-lib.sh once." >&2
    exit 1
fi
codesign --force --deep --sign - "$APP_PATH" >/dev/null

cp "$SCRIPT_DIR/terminal-characterization-driver.py" "$RUN_ROOT/driver.py"
chmod +x "$RUN_ROOT/driver.py"
mkdir -p "$ISOLATED_HOME/.config/ghostty"
cat >"$ISOLATED_HOME/.config/ghostty/config" <<EOF
command = direct:/usr/bin/python3 $RUN_ROOT/driver.py $STATE_DIRECTORY
shell-integration = none
wait-after-command = true
font-family = Menlo
font-size = 12
scrollbar = never
EOF

echo "Launching $CHARACTERIZATION_APP_NAME in $RUN_ROOT..."
env \
    HOME="$ISOLATED_HOME" \
    CFFIXED_USER_HOME="$ISOLATED_HOME" \
    TMPDIR="$ISOLATED_TMP/" \
    DANTERM_TERMINAL_CHARACTERIZATION_PATH_PROBE="$PATH_PROBE" \
    DANTERM_TERMINAL_CHARACTERIZATION_TEMP_ROOT="$ISOLATED_TMP" \
    "$APP_PATH/Contents/MacOS/$CHARACTERIZATION_APP_NAME" \
    >"$APP_LOG" 2>&1 &
APP_PID=$!

wait_for_file() {
    local path="$1"
    local description="$2"
    local deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
    while [[ ! -f "$path" ]]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "$CHARACTERIZATION_APP_NAME exited while waiting for $description" >&2
            return 1
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for $description" >&2
            return 1
        fi
        sleep 0.05
    done
}

wait_for_file "$PATH_PROBE" "the app path probe"
assert_probe_paths "$PATH_PROBE" "$RUN_ROOT"
SOCKET_PATH="$(jq -r '.socket' "$PATH_PROBE")"
RECOVERY_PATH="$(jq -r '.recovery' "$PATH_PROBE")"
wait_for_file "$STATE_DIRECTORY/ready" "the controlled PTY child"
CHILD_PID="$(cat "$STATE_DIRECTORY/pid")"
[[ "$CHILD_PID" =~ ^[0-9]+$ ]] || {
    echo "Controlled child published an invalid PID" >&2
    exit 1
}

CLI="$APP_PATH/Contents/Helpers/danterm"
export DANTERM=1
export DANTERM_SOCK="$SOCKET_PATH"

wait_for_pane() {
    local deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
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
            echo "Timed out waiting for the characterization pane" >&2
            sed -n '1,40p' "$CAPTURE_DIRECTORY/last-cli-error.txt" >&2 || true
            sed -n '1,40p' "$CAPTURE_DIRECTORY/last-model.json" >&2 || true
            return 1
        fi
        sleep 0.05
    done
}
wait_for_pane

sample_columns() {
    rm -f "$STATE_DIRECTORY/size"
    kill -WINCH "$CHILD_PID"
    wait_for_file "$STATE_DIRECTORY/size" "the child PTY size"
    read -r OBSERVED_COLUMNS OBSERVED_ROWS <"$STATE_DIRECTORY/size"
    [[ "$OBSERVED_COLUMNS" =~ ^[0-9]+$ && "$OBSERVED_ROWS" =~ ^[0-9]+$ ]]
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

resize_to_columns() {
    local target="$1"
    local attempt current_width current_height delta adjustment next_width
    for attempt in $(seq 1 30); do
        sample_columns
        if [[ "$OBSERVED_COLUMNS" -eq "$target" ]]; then
            return 0
        fi
        read -r current_width current_height <<<"$(window_size)"
        delta=$((target - OBSERVED_COLUMNS))
        adjustment=$((delta * 7))
        if [[ $adjustment -eq 0 ]]; then
            adjustment=$((delta > 0 ? 2 : -2))
        fi
        next_width=$((current_width + adjustment))
        (( next_width < 600 )) && next_width=600
        set_window_size "$next_width" "$current_height"
    done
    sample_columns
    echo "Could not reach PTY width $target; observed $OBSERVED_COLUMNS columns" >&2
    echo "Grant Accessibility permission to the current terminal and retry." >&2
    return 1
}

wait_for_pane_marker() {
    local marker="$1"
    local deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
    local probe="$RUN_ROOT/pane-marker-probe"
    while true; do
        if "$CLI" pane read --pane "$PANE_ID" --lines 200 >"$probe" 2>/dev/null \
            && grep -qF "$marker" "$probe"; then
            return 0
        fi
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for pane marker: $marker" >&2
            return 1
        fi
        sleep 0.05
    done
}

capture_stable() {
    local output="$1"
    shift
    local previous="$RUN_ROOT/previous-capture"
    local current="$RUN_ROOT/current-capture"
    local deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
    rm -f "$previous"
    while true; do
        "$CLI" pane read --pane "$PANE_ID" "$@" >"$current"
        if [[ -f "$previous" ]] && cmp -s "$previous" "$current"; then
            cp "$current" "$output"
            return 0
        fi
        cp "$current" "$previous"
        if (( SECONDS >= deadline )); then
            echo "Timed out waiting for stable pane text" >&2
            return 1
        fi
        sleep 0.05
    done
}

capture_width() {
    local name="$1"
    local target="$2"
    local directory="$CAPTURE_DIRECTORY/$name"
    mkdir -p "$directory"
    resize_to_columns "$target"
    sample_columns
    printf '%s %s\n' "$OBSERVED_COLUMNS" "$OBSERVED_ROWS" >"$directory/pty-size.txt"
    capture_stable "$directory/viewport.txt"
    capture_stable "$directory/full-over-limit.txt" --lines 200
    capture_stable "$directory/full-tail.txt" --lines 5
}

resize_to_columns "$CHARACTERIZATION_NARROW_COLUMNS"
kill -USR1 "$CHILD_PID"
wait_for_file "$STATE_DIRECTORY/primary-ready" "primary corpus output"
wait_for_pane_marker "CORPUS-END"
capture_width narrow "$CHARACTERIZATION_NARROW_COLUMNS"
capture_width wide "$CHARACTERIZATION_WIDE_COLUMNS"
capture_width narrow-after-reflow "$CHARACTERIZATION_NARROW_COLUMNS"

kill -USR2 "$CHILD_PID"
wait_for_file "$STATE_DIRECTORY/alternate-ready" "alternate-screen output"
wait_for_pane_marker "ALT-TRANSIENT"
capture_stable "$CAPTURE_DIRECTORY/alternate-viewport.txt"

kill -USR1 "$CHILD_PID"
wait_for_file "$STATE_DIRECTORY/returned-primary-ready" "returned-primary output"
wait_for_pane_marker "RETURNED-PRIMARY"
capture_stable "$CAPTURE_DIRECTORY/returned-primary-viewport.txt"
capture_stable "$CAPTURE_DIRECTORY/returned-primary-full.txt" --lines 200

osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null
on run argv
    set targetPid to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first application process whose unix id is targetPid
        set frontmost of targetProcess to true
        tell targetProcess
            repeat with candidate in menu bar items of menu bar 1
                if exists menu item "Quit DanTerm" of menu 1 of candidate then
                    click menu item "Quit DanTerm" of menu 1 of candidate
                    return
                end if
            end repeat
            error "Quit DanTerm menu item not found"
        end tell
    end tell
end run
APPLESCRIPT

quit_deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
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
        echo "Timed out waiting for the quit confirmation" >&2
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

quit_deadline=$((SECONDS + CHARACTERIZATION_TIMEOUT_SECONDS))
while kill -0 "$APP_PID" 2>/dev/null; do
    if (( SECONDS >= quit_deadline )); then
        echo "Timed out waiting for normal app termination" >&2
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
if kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "Controlled terminal child remained after clean app termination" >&2
    exit 1
fi
CHILD_PID=""

ENRICHED_CHECKPOINT="$RECOVERY_PATH/last-enriched.json"
[[ -f "$ENRICHED_CHECKPOINT" ]] || {
    echo "Clean termination did not write an enriched checkpoint" >&2
    exit 1
}
jq -j '.model.groups[].tabs[].rootNode | .. | objects | select(.type? == "leaf") | .pane.scrollback // empty' \
    "$ENRICHED_CHECKPOINT" >"$CAPTURE_DIRECTORY/enriched-scrollback.txt"

divergences='[]'
append_divergence() {
    local message="$1"
    divergences="$(jq -cn --argjson prior "$divergences" --arg message "$message" '$prior + [$message]')"
}

if ! cmp -s "$CAPTURE_DIRECTORY/narrow/full-over-limit.txt" "$CAPTURE_DIRECTORY/wide/full-over-limit.txt"; then
    append_divergence \
        "Ghostty full-history serialization changes across reflow; the terminal-engine contract requires width-invariant logical text."
fi
if [[ -s "$CAPTURE_DIRECTORY/narrow/full-over-limit.txt" ]] \
    && [[ "$(tail -c 1 "$CAPTURE_DIRECTORY/narrow/full-over-limit.txt" | od -An -tuC | tr -d ' ')" == "10" ]]; then
    append_divergence \
        "Ghostty pane-read output ends in a newline for this corpus; the terminal-engine projection does not add one merely because the range ended."
fi

EXPECTED_TAIL="$RUN_ROOT/expected-logical-tail.txt"
printf '%s' 'SPANISH: niño, acción, corazón
CHINESE: 你好世界
EMOJI: 🙂 🚀
LONG-LOGICAL:abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789-end
CORPUS-END' >"$EXPECTED_TAIL"
for width_name in narrow wide narrow-after-reflow; do
    if ! cmp -s "$EXPECTED_TAIL" "$CAPTURE_DIRECTORY/$width_name/full-tail.txt"; then
        append_divergence \
            "Ghostty pane read --lines 5 at $width_name did not return the last five logical lines with the source final-newline state."
    fi
done

if grep -qF 'ALT-TRANSIENT' "$CAPTURE_DIRECTORY/enriched-scrollback.txt"; then
    append_divergence \
        "Ghostty enriched recovery retained transient alternate-screen text; the terminal-engine contract retains primary history only."
fi
if ! grep -qF 'HISTORY-01' "$CAPTURE_DIRECTORY/enriched-scrollback.txt"; then
    append_divergence \
        "Ghostty enriched recovery omitted the controlled primary-screen history."
fi
if ! grep -qF 'RETURNED-PRIMARY' "$CAPTURE_DIRECTORY/enriched-scrollback.txt"; then
    append_divergence \
        "Ghostty enriched recovery omitted activity written after returning to the primary screen."
fi
recovery_last_byte="$(tail -c 1 "$CAPTURE_DIRECTORY/enriched-scrollback.txt" | od -An -tuC | xargs)"
recovery_last_two_bytes="$(tail -c 2 "$CAPTURE_DIRECTORY/enriched-scrollback.txt" | od -An -tuC | xargs)"
if [[ "$recovery_last_byte" != "10" || "$recovery_last_two_bytes" == "10 10" ]]; then
    append_divergence \
        "Ghostty enriched recovery did not store non-empty replay text with exactly one final newline."
fi
EXPECTED_RECOVERY="$RUN_ROOT/expected-enriched-scrollback.txt"
cp "$CAPTURE_DIRECTORY/returned-primary-full.txt" "$EXPECTED_RECOVERY"
printf '\n' >>"$EXPECTED_RECOVERY"
if ! cmp -s "$EXPECTED_RECOVERY" "$CAPTURE_DIRECTORY/enriched-scrollback.txt"; then
    append_divergence \
        "Ghostty enriched recovery did not match the persistence-normalized returned-primary full history."
fi

ACTUAL_FIXTURE="$CAPTURE_DIRECTORY/ghostty-inspection-recovery.json"
jq -nS \
    --argjson narrowColumns "$CHARACTERIZATION_NARROW_COLUMNS" \
    --argjson wideColumns "$CHARACTERIZATION_WIDE_COLUMNS" \
    --rawfile narrowSize "$CAPTURE_DIRECTORY/narrow/pty-size.txt" \
    --rawfile narrowViewport "$CAPTURE_DIRECTORY/narrow/viewport.txt" \
    --rawfile narrowFull "$CAPTURE_DIRECTORY/narrow/full-over-limit.txt" \
    --rawfile narrowTail "$CAPTURE_DIRECTORY/narrow/full-tail.txt" \
    --rawfile wideSize "$CAPTURE_DIRECTORY/wide/pty-size.txt" \
    --rawfile wideViewport "$CAPTURE_DIRECTORY/wide/viewport.txt" \
    --rawfile wideFull "$CAPTURE_DIRECTORY/wide/full-over-limit.txt" \
    --rawfile wideTail "$CAPTURE_DIRECTORY/wide/full-tail.txt" \
    --rawfile narrowAgainSize "$CAPTURE_DIRECTORY/narrow-after-reflow/pty-size.txt" \
    --rawfile narrowAgainViewport "$CAPTURE_DIRECTORY/narrow-after-reflow/viewport.txt" \
    --rawfile narrowAgainFull "$CAPTURE_DIRECTORY/narrow-after-reflow/full-over-limit.txt" \
    --rawfile narrowAgainTail "$CAPTURE_DIRECTORY/narrow-after-reflow/full-tail.txt" \
    --rawfile alternateViewport "$CAPTURE_DIRECTORY/alternate-viewport.txt" \
    --rawfile returnedViewport "$CAPTURE_DIRECTORY/returned-primary-viewport.txt" \
    --rawfile returnedFull "$CAPTURE_DIRECTORY/returned-primary-full.txt" \
    --rawfile enrichedScrollback "$CAPTURE_DIRECTORY/enriched-scrollback.txt" \
    --argjson divergences "$divergences" \
    '{
        format: 1,
        backend: "Ghostty v1.3.1 through DanTerm app and bundled CLI",
        widths: {narrow: $narrowColumns, wide: $wideColumns},
        captures: {
            narrow: {ptySize: $narrowSize, viewport: $narrowViewport, fullOverLimit: $narrowFull, fullTail: $narrowTail},
            wide: {ptySize: $wideSize, viewport: $wideViewport, fullOverLimit: $wideFull, fullTail: $wideTail},
            narrowAfterReflow: {ptySize: $narrowAgainSize, viewport: $narrowAgainViewport, fullOverLimit: $narrowAgainFull, fullTail: $narrowAgainTail},
            alternateViewport: $alternateViewport,
            returnedPrimaryViewport: $returnedViewport,
            returnedPrimaryFull: $returnedFull,
            enrichedScrollback: $enrichedScrollback
        },
        divergencesFromTerminalEngineContract: $divergences
    }' >"$ACTUAL_FIXTURE"

FAILURE_DIRECTORY="$FAILURE_ROOT/$(date +%Y-%m-%d-%H%M%S)-$$"
assert_fixture "$FIXTURE" "$ACTUAL_FIXTURE" \
    "ghostty-inspection-recovery.json" "$FAILURE_DIRECTORY"

SUITE_SUCCEEDED=1
rm -rf "$FAILURE_DIRECTORY" 2>/dev/null || true
echo "Terminal characterization passed at $CHARACTERIZATION_NARROW_COLUMNS and $CHARACTERIZATION_WIDE_COLUMNS columns."
