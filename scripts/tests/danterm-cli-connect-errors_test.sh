#!/usr/bin/env bash
# Verify the standalone CLI classifies control-socket connection failures without
# contacting, launching, or otherwise controlling a running DanTerm app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod 700 "$TMP/denied" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# shellcheck source=../lib/bounded-wait.sh
source "$ROOT_DIR/scripts/lib/bounded-wait.sh"

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

run_cli() {
    local name="$1"
    local socket_path="$2"
    set +e
    DANTERM_SOCK="$socket_path" "$CLI" ls >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"
    status=$?
    set -e
}

assert_result() {
    local name="$1"
    local expected_stderr="$2"
    printf '%s\n' "$expected_stderr" > "$TMP/$name.expected-stderr"
    [[ "$status" -eq 1 ]] || fail "$name exited $status instead of 1"
    [[ ! -s "$TMP/$name.stdout" ]] || fail "$name wrote to stdout"
    if ! cmp -s "$TMP/$name.expected-stderr" "$TMP/$name.stderr"; then
        fail "$name stderr did not match expected output"
    fi
}

cd "$ROOT_DIR"
swift build --product DanTermCLI
CLI="$(swift build --show-bin-path)/DanTermCLI"

missing_socket="$TMP/missing.sock"
run_cli missing "$missing_socket"
assert_result missing "danterm: DanTerm is not running"

refused_socket="$TMP/refused.sock"
nc -lU "$refused_socket" >/dev/null 2>&1 &
listener_pid=$!
for _ in {1..50}; do
    [[ -S "$refused_socket" ]] && break
    sleep 0.01
done
kill "$listener_pid"
reap_pid "$listener_pid"
[[ -S "$refused_socket" ]] || fail "refused fixture did not create a socket"
run_cli refused "$refused_socket"
assert_result refused "danterm: DanTerm is not running"

mkdir "$TMP/denied"
chmod 000 "$TMP/denied"
denied_socket="$TMP/denied/control.sock"
run_cli denied "$denied_socket"
assert_result denied "danterm: cannot access control socket (sandbox or permissions): $denied_socket"
chmod 700 "$TMP/denied"

not_directory="$TMP/not-directory"
printf 'fixture\n' > "$not_directory"
generic_socket="$not_directory/control.sock"
LC_ALL=C run_cli generic "$generic_socket"
assert_result generic "danterm: cannot connect to control socket (Not a directory): $generic_socket"

[[ "$failures" -eq 0 ]] || exit 1
echo "danterm CLI connection-error self-test passed"
