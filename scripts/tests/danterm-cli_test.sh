#!/usr/bin/env bash
# Smoke-test the bundled danterm CLI against a running DanTerm Dev app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="DanTerm Dev"
APP_PATH="$HOME/Applications/$APP_NAME.app"
CLI_PATH="$APP_PATH/Contents/Helpers/danterm"

if [[ "${DANTERM_CLI_TEST_ALLOW_APP_CONTROL:-}" != "1" ]]; then
    echo "Refusing to launch or quit $APP_NAME without DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1" >&2
    exit 2
fi

"$SCRIPT_DIR/dev-build.sh"

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
grep -qF 'pane info [--pane <pane-id>]' "$err"
grep -qF 'tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]' "$err"
grep -qF 'tab close [--tab <tab-id>]' "$err"
grep -qF 'pane split [--pane <pane-id>] -h|-v' "$err"
grep -qF 'pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]' "$err"
grep -qF 'agent attach --kind <kind> --id <session-id>' "$err"
grep -qF 'todo clear-completed [--pane <pane-id>]' "$err"
grep -qF 'doctor [--all|-v]' "$err"
grep -qF 'tab new opens in the background at the target group end' "$err"
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
    grep -qF 'pane info [--pane <pane-id>]' "$out"
    grep -qF 'tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]' "$out"
    grep -qF 'tab close [--tab <tab-id>]' "$out"
    grep -qF 'pane split [--pane <pane-id>] -h|-v' "$out"
    grep -qF 'pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]' "$out"
    grep -qF 'agent attach --kind <kind> --id <session-id>' "$out"
    grep -qF 'todo clear-completed [--pane <pane-id>]' "$out"
    grep -qF 'doctor [--all|-v]' "$out"
    grep -qF 'tab new opens in the background at the target group end' "$out"
    grep -qF 'DANTERM_SOCK' "$out"
    grep -qF 'DANTERM_PANE' "$out"
    ! grep -qF 'DANTERM_TAB' "$out"
done

# `doctor` is local-only like help: it must work before the app launches and
# must not surface the socket error text.
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
! grep -qF 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor --all
[[ $status -eq 0 ]]
[[ -s "$out" ]]
[[ ! -s "$err" ]]
grep -qF 'OK ' "$out"
! grep -qF 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor --bogus
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --bogus' "$err"
! grep -qF 'DanTerm is not running' "$out" "$err"
rm -rf "$doctor_home"

pkill -x "$APP_NAME" 2>/dev/null || true
open -a "$APP_PATH"

socket=""
for _ in $(seq 1 30); do
    socket="$(find "$HOME/Library/Caches/com.danneu.danterm-dev" -name control.sock -type s 2>/dev/null | head -1 || true)"
    if [[ -n "$socket" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "$socket" ]]; then
    echo "DanTerm control socket did not appear" >&2
    exit 1
fi

export DANTERM=1
export DANTERM_SOCK="$socket"

model=""
pane_id=""
tab_id=""
group_id=""
for _ in $(seq 1 30); do
    if model="$("$CLI_PATH" ls 2>/dev/null)" \
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

info="$("$CLI_PATH" pane info --pane "$pane_id")"
printf '%s\n' "$info" | jq -e \
    --arg pane "$pane_id" \
    --arg tab "$tab_id" \
    --arg group "$group_id" \
    '.pane.id == $pane and .tab.id == $tab and .group.id == $group' >/dev/null

"$CLI_PATH" tab rename --tab "$tab_id" test123
"$CLI_PATH" ls | jq -e \
    --arg tab "$tab_id" \
    '.groups[].tabs[] | select(.id == $tab and .customTitle == "test123")' >/dev/null

"$CLI_PATH" tab new --group "$group_id" --title smoke-tab | jq -e '.tab.id and .panes[0].id' >/dev/null
"$CLI_PATH" tab new --group "$group_id" --at-group-end --title smoke-tab-end | jq -e '.tab.id and .panes[0].id' >/dev/null
close_id="$("$CLI_PATH" tab new --group "$group_id" --title close-test | jq -r '.tab.id')"
"$CLI_PATH" tab close --tab "$close_id"
"$CLI_PATH" ls | jq -e --arg t "$close_id" '[.groups[].tabs[] | select(.id == $t)] | length == 0' >/dev/null
split_pane_id="$("$CLI_PATH" pane split --pane "$pane_id" -h --title smoke-split | jq -r '.pane.id')"
[[ -n "$split_pane_id" && "$split_pane_id" != "null" ]]

"$CLI_PATH" theme set --pane "$pane_id" SmokeTheme
"$CLI_PATH" theme set --pane "$pane_id" --clear

todo_id="$("$CLI_PATH" todo add 'ship cli' | jq -r '.todo.id')"
"$CLI_PATH" todo list --pane "$pane_id" | jq -e --arg id "$todo_id" '.todos[] | select(.id == $id)' >/dev/null
"$CLI_PATH" todo edit --pane "$pane_id" "$todo_id" 'ship cli v2'
"$CLI_PATH" todo "done" --pane "$pane_id" "$todo_id"
"$CLI_PATH" todo delete --pane "$pane_id" "$todo_id"

/usr/bin/python3 - "$DANTERM_SOCK" <<'PY'
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

pkill -x "$APP_NAME" 2>/dev/null || true
for _ in $(seq 1 10); do
    [[ ! -S "$socket" ]] && break
    sleep 0.5
done
if env -u DANTERM_PANE "$CLI_PATH" ls >/tmp/danterm-cli-smoke.out 2>/tmp/danterm-cli-smoke.err; then
    echo "danterm ls unexpectedly succeeded after app quit" >&2
    exit 1
fi
grep -qx 'danterm: DanTerm is not running' /tmp/danterm-cli-smoke.err
