#!/usr/bin/env bash
# Smoke-test the bundled danterm CLI against an isolated development slot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CLI_PATH="$SCRIPT_DIR/.build/DanTerm Dev.app/Contents/Helpers/danterm"
launch_output="$(mktemp)"
launch_error="$(mktemp)"
smoke_output="$(mktemp)"
smoke_error="$(mktemp)"
launcher_pid=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$launcher_pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
    rm -f "$launch_output" "$launch_error" "$smoke_output" "$smoke_error"
    exit "$status"
}
trap cleanup EXIT INT TERM

python3 "$SCRIPT_DIR/scripts/dev-slot-launcher.py" >"$launch_output" 2>"$launch_error" &
launcher_pid=$!
handle=""
for _ in $(seq 1 180); do
    if [[ -s "$launch_output" ]]; then
        handle="$(tail -1 "$launch_output")"
        printf '%s\n' "$handle" | jq -e . >/dev/null 2>&1 && break
    fi
    kill -0 "$launcher_pid" 2>/dev/null || {
        echo "DanTerm slot launcher exited before emitting a handle" >&2
        cat "$launch_error" >&2
        exit 1
    }
    sleep 1
done
printf '%s\n' "$handle" | jq -e . >/dev/null 2>&1 || {
    echo "DanTerm slot launcher did not emit a handle" >&2
    cat "$launch_error" >&2
    exit 1
}
socket="$(printf '%s\n' "$handle" | jq -er '.socketPath')"
bundle_id="$(printf '%s\n' "$handle" | jq -er '.bundleId')"
reported_pid="$(printf '%s\n' "$handle" | jq -er '.pid')"
slot="$(printf '%s\n' "$handle" | jq -er '.slot')"
[[ "$slot" -ge 1 && "$slot" -le 8 ]]
[[ "$bundle_id" == "com.danneu.danterm-dev.$slot" ]]
[[ "$reported_pid" == "$launcher_pid" ]]
[[ "$socket" == "$HOME/Library/Caches/$bundle_id/control.sock" ]]

# Help-text smoke tests. These run against the freshly built helper but
# do not require the app to be running -- help is local arg handling.
out=$(mktemp); err=$(mktemp)
run_cli() {
    : >"$out"
    : >"$err"
    if "$CLI_PATH" "$@" >"$out" 2>"$err"; then
        status=0
    else
        status=$?
    fi
}

# Bare `danterm`: usage on stderr, exit 1, stdout silent. We assert
# stderr does NOT carry the old `danterm:` error-line prefix so that a
# regression which prepends `danterm: missing command` before/with the
# usage block fails loudly.
run_cli
[[ $status -eq 1 ]]
[[ ! -s "$out" ]]
[[ -s "$err" ]]
if grep -q '^danterm:' "$err"; then
    echo "regression: bare invocation prefixed with 'danterm:'" >&2
    exit 1
fi
grep -qF 'Usage:' "$err"
grep -qF 'ls' "$err"
grep -qE '^ *focus +Print the main window' "$err"
grep -qF 'pane info --pane <pane-id>' "$err"
grep -qF 'tab new (--group <group-id> | --after-tab <tab-id>)' "$err"
grep -qF 'tab close --tab <tab-id>' "$err"
grep -qF 'pane split --pane <pane-id> -h|-v' "$err"
grep -qF 'pane close --pane <pane-id>' "$err"
grep -qF 'agent attach --pane <pane-id> --kind <kind> --id <session-id>' "$err"
grep -qF 'agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>' "$err"
grep -qF 'agent detach --pane <pane-id> --kind <kind> --id <session-id>' "$err"
grep -qF 'todo clear-completed --pane <pane-id>' "$err"
grep -qE '^ *doctor +Check DanTerm integration health' "$err"
grep -qE '^ *skill +Print DanTerm' "$err"
! grep -qF 'doctor [--all|-v]' "$err"
grep -qF 'tab new opens in the background at the target group end' "$err"
grep -qF 'danterm [--socket <path>] <command> [args]' "$err"
grep -qF 'DANTERM_SOCK' "$err"
grep -qF 'DANTERM_PANE' "$err"
! grep -qF 'DANTERM_TAB' "$err"

# Explicit help requests: usage on stdout, exit 0, stderr silent. Same
# stable tokens checked across each flag form.
for help_arg in help --help -h; do
    run_cli "$help_arg"
    [[ $status -eq 0 ]]
    [[ ! -s "$err" ]]
    [[ -s "$out" ]]
    grep -qF 'Usage:' "$out"
    grep -qF 'ls' "$out"
    grep -qE '^ *focus +Print the main window' "$out"
    grep -qF 'pane info --pane <pane-id>' "$out"
    grep -qF 'tab new (--group <group-id> | --after-tab <tab-id>)' "$out"
    grep -qF 'tab close --tab <tab-id>' "$out"
    grep -qF 'pane split --pane <pane-id> -h|-v' "$out"
    grep -qF 'pane close --pane <pane-id>' "$out"
    grep -qF 'agent attach --pane <pane-id> --kind <kind> --id <session-id>' "$out"
    grep -qF 'agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>' "$out"
    grep -qF 'agent detach --pane <pane-id> --kind <kind> --id <session-id>' "$out"
    grep -qF 'todo clear-completed --pane <pane-id>' "$out"
    grep -qE '^ *doctor +Check DanTerm integration health' "$out"
    grep -qE '^ *skill +Print DanTerm' "$out"
    ! grep -qF 'doctor [--all|-v]' "$out"
    grep -qF 'tab new opens in the background at the target group end' "$out"
    grep -qF 'danterm [--socket <path>] <command> [args]' "$out"
    grep -qF 'DANTERM_SOCK' "$out"
    grep -qF 'DANTERM_PANE' "$out"
    ! grep -qF 'DANTERM_TAB' "$out"
done

# `skill` is local-only and emits the canonical bundled skill bytes without
# consulting pane targeting or the control socket. Exercise the helper directly
# and through the shape installed on PATH.
export DANTERM_SOCK="$launch_output/unusable.sock"
run_cli skill
[[ $status -eq 0 ]]
[[ ! -s "$err" ]]
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" "$out"

skill_bin=$(mktemp -d)
ln -s "$CLI_PATH" "$skill_bin/danterm"
: >"$out"
: >"$err"
if PATH="$skill_bin:$PATH" danterm skill >"$out" 2>"$err"; then
    status=0
else
    status=$?
fi
[[ $status -eq 0 ]]
[[ ! -s "$err" ]]
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" "$out"

run_cli skill extra
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unexpected argument: extra' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
run_cli skill --bogus
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --bogus' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"

missing_bundle="$skill_bin/Missing.app"
mkdir -p "$missing_bundle/Contents/Helpers"
cp "$CLI_PATH" "$missing_bundle/Contents/Helpers/danterm"
: >"$out"
: >"$err"
if "$missing_bundle/Contents/Helpers/danterm" skill >"$out" 2>"$err"; then
    status=0
else
    status=$?
fi
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: bundled skill is missing or unreadable' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
rm -rf "$skill_bin"

# `doctor` keeps its local checks available before the app launches; app-owned
# permission rows skip without surfacing a socket error.
doctor_home=$(mktemp -d)
run_doctor_with_temp_home() {
    : >"$out"
    : >"$err"
    if HOME="$doctor_home" CODEX_HOME="$doctor_home/.codex" "$CLI_PATH" "$@" >"$out" 2>"$err"; then
        status=0
    else
        status=$?
    fi
}
run_doctor_with_temp_home doctor
[[ $status -eq 0 ]]
[[ -s "$out" ]]
[[ ! -s "$err" ]]
grep -qF 'OK ' "$out"
grep -qF 'SKIP Notifications enabled: DanTerm is not running, so its permissions cannot be checked.' "$out"
grep -qF 'SKIP Full Disk Access permission granted: DanTerm is not running, so its permissions cannot be checked.' "$out"
grep -qF 'SKIP Developer Tools permission granted: DanTerm is not running, so its permissions cannot be checked.' "$out"
! grep -qF 'DanTerm is not running' "$err"
run_doctor_with_temp_home doctor --all
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --all' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor -v
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: -v' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor --bogus
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --bogus' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
rm -rf "$doctor_home"

for _ in $(seq 1 30); do
    if [[ -S "$socket" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$socket" ]]; then
    echo "DanTerm control socket did not appear" >&2
    exit 1
fi

export DANTERM=1
export DANTERM_SOCK="$launch_output/wrong.sock"

slot_cli() {
    "$CLI_PATH" --socket "$socket" "$@"
}

model=""
pane_id=""
tab_id=""
group_id=""
for _ in $(seq 1 30); do
    if model="$(slot_cli ls 2>/dev/null)" \
        && tab_id="$(printf '%s\n' "$model" | jq -er '.selectedTabId // empty')" \
        && pane_id="$(printf '%s\n' "$model" | jq -er --arg tab "$tab_id" '.groups[].tabs[] | select(.id == $tab) | .focusedPaneId // empty')" \
        && group_id="$(printf '%s\n' "$model" | jq -er --arg tab "$tab_id" '.groups[] | select([.tabs[].id] | index($tab)) | .id')"; then
        break
    fi
    sleep 1
done
if [[ -z "$pane_id" || -z "$tab_id" || -z "$group_id" ]]; then
    echo "DanTerm model did not expose an active pane" >&2
    exit 1
fi

printf '%s\n' "$model" | jq .groups >/dev/null
export DANTERM_PANE="$pane_id"
slot_cli pane tape --pane "$pane_id" | jq -e '.events' >/dev/null
slot_cli focus | jq -e --arg pane "$pane_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null

info="$(slot_cli pane info --pane "$pane_id")"
printf '%s\n' "$info" | jq -e \
    --arg pane "$pane_id" \
    --arg tab "$tab_id" \
    --arg group "$group_id" \
    '.pane.id == $pane and .tab.id == $tab and .group.id == $group' >/dev/null

slot_cli tab rename --tab "$tab_id" test123
slot_cli ls | jq -e \
    --arg tab "$tab_id" \
    '.groups[].tabs[] | select(.id == $tab and .customTitle == "test123")' >/dev/null

other_pane_id="$(slot_cli tab new --group "$group_id" --title smoke-tab | jq -er '.panes[0].id')"
focused_split_id="$(slot_cli pane split --pane "$pane_id" -h --foreground --title focus-foreground | jq -er '.pane.id')"
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane zoom --pane "$focused_split_id" on | jq -e '.tab.isZoomed == true' >/dev/null
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane zoom --pane "$focused_split_id" off | jq -e '.tab.isZoomed == false' >/dev/null
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
background_split_id="$(slot_cli pane split --pane "$other_pane_id" -v --foreground --title focus-background | jq -er '.pane.id')"
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane close --pane "$background_split_id"
slot_cli pane close --pane "$focused_split_id"
slot_cli focus | jq -e --arg pane "$pane_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli tab new --group "$group_id" --at-group-end --title smoke-tab-end | jq -e '.tab.id and .panes[0].id' >/dev/null
close_id="$(slot_cli tab new --group "$group_id" --title close-test | jq -r '.tab.id')"
slot_cli tab close --tab "$close_id"
slot_cli ls | jq -e --arg t "$close_id" '[.groups[].tabs[] | select(.id == $t)] | length == 0' >/dev/null
split_pane_id="$(slot_cli pane split --pane "$pane_id" -h --title smoke-split | jq -r '.pane.id')"
[[ -n "$split_pane_id" && "$split_pane_id" != "null" ]]

run_cli --socket "$socket" pane close --pane "$split_pane_id"
[[ $status -eq 0 ]]
[[ ! -s "$out" ]]
[[ ! -s "$err" ]]
slot_cli ls | jq -e \
    --arg pane "$split_pane_id" \
    --arg tab "$tab_id" \
    '([.. | objects | select(.id? == $pane)] | length == 0) and ([.groups[].tabs[] | select(.id == $tab)] | length == 1)' >/dev/null

run_cli --socket "$socket" pane close
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: usage: danterm pane close --pane <pane-id>' "$err"

slot_cli pane focus "$other_pane_id"
slot_cli theme set --pane "$pane_id" SmokeTheme
slot_cli ls | jq -e \
    --arg target "$pane_id" \
    --arg focused "$other_pane_id" \
    '([.. | objects | select(.id? == $target and .theme? == "SmokeTheme")] | length == 1)
     and ([.. | objects | select(.id? == $focused and .theme? == null)] | length == 1)' >/dev/null
run_cli --socket "$socket" theme set SmokeTheme
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: usage: danterm theme set --pane <pane-id> <name>|--clear' "$err"
slot_cli ls | jq -e \
    --arg target "$pane_id" \
    --arg focused "$other_pane_id" \
    '([.. | objects | select(.id? == $target and .theme? == "SmokeTheme")] | length == 1)
     and ([.. | objects | select(.id? == $focused and .theme? == null)] | length == 1)' >/dev/null
slot_cli theme set --pane "$pane_id" --clear

todo_id="$(slot_cli todo add --pane "$pane_id" 'ship cli' | jq -r '.todo.id')"
slot_cli todo list --pane "$pane_id" | jq -e --arg id "$todo_id" '.todos[] | select(.id == $id)' >/dev/null
slot_cli todo edit --pane "$pane_id" "$todo_id" 'ship cli v2'
slot_cli todo "done" --pane "$pane_id" "$todo_id"
slot_cli todo delete --pane "$pane_id" "$todo_id"

/usr/bin/python3 - "$socket" <<'PY'
import json
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(5)
    sock.connect(sys.argv[1])
    stream = sock.makefile("rwb")
    stream.readline()
    stream.write(b'{"jsonrpc":"2.0","id":1,"method":"unknown"}\n')
    stream.flush()
    for raw in stream:
        response = json.loads(raw)
        if response.get("id") == 1:
            code = response.get("error", {}).get("code")
            if code != -32601:
                raise SystemExit(f"expected -32601, got {code!r}")
            break
    else:
        raise SystemExit("no response for unknown method")
PY

kill -TERM "$launcher_pid"
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
for _ in $(seq 1 10); do
    [[ ! -S "$socket" ]] && break
    sleep 0.5
done
if env -u DANTERM_PANE "$CLI_PATH" --socket "$socket" ls >"$smoke_output" 2>"$smoke_error"; then
    echo "danterm ls unexpectedly succeeded after app quit" >&2
    exit 1
fi
grep -qx 'danterm: DanTerm is not running' "$smoke_error"
