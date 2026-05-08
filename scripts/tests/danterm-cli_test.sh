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
grep -qF 'pane split -h|-v' "$err"
grep -qF 'todo clear-completed' "$err"
grep -qF 'DANTERM_SOCK' "$err"

# Explicit help requests: usage on stdout, exit 0, stderr silent. Same
# stable tokens checked across each flag form.
for help_arg in help --help -h; do
    run_cli "$help_arg"
    [[ $status -eq 0 ]]
    [[ ! -s "$err" ]]
    [[ -s "$out" ]]
    grep -qF 'Usage:' "$out"
    grep -qF 'ls' "$out"
    grep -qF 'pane split -h|-v' "$out"
    grep -qF 'todo clear-completed' "$out"
    grep -qF 'DANTERM_SOCK' "$out"
done

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
for _ in $(seq 1 30); do
    if model="$("$CLI_PATH" ls 2>/dev/null)" \
        && pane_id="$(printf '%s\n' "$model" | jq -er '.panes[0].id // empty')" \
        && tab_id="$(printf '%s\n' "$model" | jq -er '.selectedTabId // empty')"; then
        break
    fi
    sleep 1
done
if [[ -z "$pane_id" || -z "$tab_id" ]]; then
    echo "DanTerm model did not expose an active pane" >&2
    exit 1
fi

printf '%s\n' "$model" | jq .groups >/dev/null
export DANTERM_PANE="$pane_id"
export DANTERM_TAB="$tab_id"

"$CLI_PATH" tab title test123
[[ "$("$CLI_PATH" tab title)" == "test123" ]]

todo_id="$("$CLI_PATH" todo add 'ship cli' | jq -r .id)"
"$CLI_PATH" todo list | jq -e --arg id "$todo_id" '.[] | select(.id == $id)' >/dev/null
"$CLI_PATH" todo edit "$todo_id" 'ship cli v2'
"$CLI_PATH" todo "done" "$todo_id"
"$CLI_PATH" todo delete "$todo_id"

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
if env -u DANTERM_PANE -u DANTERM_TAB "$CLI_PATH" ls >/tmp/danterm-cli-smoke.out 2>/tmp/danterm-cli-smoke.err; then
    echo "danterm ls unexpectedly succeeded after app quit" >&2
    exit 1
fi
grep -qx 'danterm: DanTerm is not running' /tmp/danterm-cli-smoke.err
