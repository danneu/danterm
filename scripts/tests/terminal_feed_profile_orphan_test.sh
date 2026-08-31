#!/usr/bin/env bash
# Behavioral coverage for the executable's finite profile lifetime and input guards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SANDBOX="$(mktemp -d "$ROOT_DIR/.build/feed-profile-orphan-test.XXXXXX")"
harness_pid=""
parent_pid=""
writer_pid=""

cleanup() {
    local status=$?
    for pid in "$harness_pid" "$parent_pid" "$writer_pid"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$SANDBOX"
    exit "$status"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

wait_until_gone() {
    local pid="$1" deadline=$((SECONDS + 30))
    while ((SECONDS < deadline)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
    done
    return 1
}

swift build --package-path "$ROOT_DIR/lib/TerminalCore" --product TerminalCoreBenchmark >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR/lib/TerminalCore" --show-bin-path)"
HARNESS="$BIN_DIR/TerminalCoreBenchmark"
: >"$SANDBOX/fixture.bin"

# The parent dies without running cleanup. The child's own duration remains authoritative.
sh -c '"$1" --profile 0.2 <"$2" & echo $! >"$3"; wait' sh \
    "$HARNESS" "$SANDBOX/fixture.bin" "$SANDBOX/harness.pid" &
parent_pid=$!
while [[ ! -s "$SANDBOX/harness.pid" ]]; do sleep 0.05; done
harness_pid="$(cat "$SANDBOX/harness.pid")"
kill -9 "$parent_pid"
wait "$parent_pid" 2>/dev/null || true
parent_pid=""
wait_until_gone "$harness_pid" || fail "profile harness outlived its declared window"
harness_pid=""

# A FIFO writer stays open, so reading stdin would hang. Profile mode must reject it first.
mkfifo "$SANDBOX/fixture.fifo"
tail -f /dev/null >"$SANDBOX/fixture.fifo" &
writer_pid=$!
"$HARNESS" --profile 1 <"$SANDBOX/fixture.fifo" \
    >"$SANDBOX/fifo.stdout" 2>"$SANDBOX/fifo.stderr" &
harness_pid=$!
wait_until_gone "$harness_pid" || fail "profile harness blocked while reading a FIFO"
if wait "$harness_pid"; then
    fail "profile harness accepted a FIFO"
fi
harness_pid=""
kill "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true
writer_pid=""

for duration in missing 0 -1 nope 1e100; do
    if [[ "$duration" == missing ]]; then
        arguments=(--profile)
    else
        arguments=(--profile "$duration")
    fi
    if "$HARNESS" "${arguments[@]}" <"$SANDBOX/fixture.bin" \
        >"$SANDBOX/invalid.stdout" 2>"$SANDBOX/invalid.stderr"; then
        fail "profile harness accepted duration '$duration'"
    fi
    grep -q '^usage:' "$SANDBOX/invalid.stderr" \
        || fail "profile harness read input before rejecting duration '$duration'"
done

echo "terminal feed profile orphan test passed"
