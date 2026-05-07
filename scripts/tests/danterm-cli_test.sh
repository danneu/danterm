#!/usr/bin/env bash
# Smoke-test the bundled danterm CLI against a running DanTerm Dev app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="DanTerm Dev"
APP_PATH="$HOME/Applications/$APP_NAME.app"
CLI_PATH="$APP_PATH/Contents/MacOS/danterm"

if [[ "${DANTERM_CLI_TEST_ALLOW_APP_CONTROL:-}" != "1" ]]; then
    echo "Refusing to launch or quit $APP_NAME without DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1" >&2
    exit 2
fi

"$SCRIPT_DIR/dev-build.sh"

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

model="$("$CLI_PATH" ls)"
printf '%s\n' "$model" | jq .groups >/dev/null
export DANTERM_PANE="$(printf '%s\n' "$model" | jq -r '.panes[0].id')"
export DANTERM_TAB="$(printf '%s\n' "$model" | jq -r '.selectedTabId')"

"$CLI_PATH" tab title test123
[[ "$("$CLI_PATH" tab title)" == "test123" ]]

todo_id="$("$CLI_PATH" todo add 'ship cli' | jq -r .id)"
"$CLI_PATH" todo list | jq -e --arg id "$todo_id" '.[] | select(.id == $id)' >/dev/null
"$CLI_PATH" todo edit "$todo_id" 'ship cli v2'
"$CLI_PATH" todo done "$todo_id"
"$CLI_PATH" todo delete "$todo_id"

printf '{"jsonrpc":"2.0","id":1,"method":"unknown"}\n' | nc -N -U "$DANTERM_SOCK" | jq -e -s '.[1].error.code == -32601' >/dev/null

pkill -x "$APP_NAME" 2>/dev/null || true
for _ in $(seq 1 10); do
    [[ ! -S "$socket" ]] && break
    sleep 0.5
done
if "$CLI_PATH" ls >/tmp/danterm-cli-smoke.out 2>/tmp/danterm-cli-smoke.err; then
    echo "danterm ls unexpectedly succeeded after app quit" >&2
    exit 1
fi
grep -qx 'danterm: DanTerm is not running' /tmp/danterm-cli-smoke.err
