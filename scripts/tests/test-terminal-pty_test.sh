#!/usr/bin/env bash
# Behavioral self-test for TerminalPTY test cache invalidation, the two-lane
# split that reruns the process-wide fd census solo, and the repository clean
# contract. It uses a fake Swift driver so cache decisions stay observable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/test-terminal-pty.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fixture="$TMP/repo"
mkdir -p "$fixture/lib/TerminalCore/Sources/TerminalCore"
mkdir -p "$fixture/lib/TerminalPTY"
mkdir -p "$fixture/.build/test-terminal-pty"
printf '// manifest\n' > "$fixture/lib/TerminalCore/Package.swift"
printf '// source a\n' > "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"

fake_swift="$TMP/swift"
cat > "$fake_swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >> "$DANTERM_TEST_SWIFT_LOG"
printf '\n' >> "$DANTERM_TEST_SWIFT_LOG"
if [[ "${1:-}" == "test" && -e "$DANTERM_TEST_SWIFT_FAIL" ]]; then
    exit 17
fi
if [[ "${1:-}" == "test" && -e "$DANTERM_TEST_SWIFT_HANG" ]]; then
    printf '%s\n' "$$" > "$DANTERM_TEST_SWIFT_HANG_PID"
    while true; do sleep 1; done
fi
EOF
chmod +x "$fake_swift"

swift_log="$TMP/swift.log"
swift_fail="$TMP/swift-fail"
swift_hang="$TMP/swift-hang"
swift_hang_pid="$TMP/swift-hang.pid"
export DANTERM_REPO_ROOT="$fixture"
export DANTERM_SWIFT="$fake_swift"
export DANTERM_TEST_SWIFT_LOG="$swift_log"
export DANTERM_TEST_SWIFT_FAIL="$swift_fail"
export DANTERM_TEST_SWIFT_HANG="$swift_hang"
export DANTERM_TEST_SWIFT_HANG_PID="$swift_hang_pid"

run_wrapper() {
    "$WRAPPER" "$@"
}

clean_count() {
    grep -c '^<package><--package-path>.*<clean>$' "$swift_log" || true
}

# The wrapper runs two test lanes: a parallel lane that skips the process-wide
# fd census test, then a solo lane running only that census test.
parallel_count() {
    grep -c '^<test><--package-path>.*<--skip><rapidCloseStressLeavesNoResources>' "$swift_log" || true
}

census_count() {
    grep -c '^<test><--package-path>.*<--filter><rapidCloseStressLeavesNoResources>$' "$swift_log" || true
}

assert_counts() {
    local expected_cleans="$1"
    local expected_parallels="$2"
    local expected_censuses="$3"
    local label="$4"
    [[ "$(clean_count)" == "$expected_cleans" ]] || fail "$label: expected $expected_cleans cleans"
    [[ "$(parallel_count)" == "$expected_parallels" ]] || fail "$label: expected $expected_parallels parallel lanes"
    [[ "$(census_count)" == "$expected_censuses" ]] || fail "$label: expected $expected_censuses census lanes"
}

: > "$swift_log"
run_wrapper --filter FocusedTests/testExample
assert_counts 1 1 1 "first run"
grep -q '<--skip><rapidCloseStressLeavesNoResources><--filter><FocusedTests/testExample>$' "$swift_log" \
    || fail "focused-test arguments were not forwarded to the parallel lane"
stamp="$fixture/.build/test-terminal-pty/terminal-core.sha256"
[[ -s "$stamp" ]] || fail "successful first run did not publish a fingerprint"

run_wrapper
assert_counts 1 2 2 "warm run"

printf '// manifest changed\n' >> "$fixture/lib/TerminalCore/Package.swift"
run_wrapper
assert_counts 2 3 3 "manifest change"

printf '// source changed\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
run_wrapper
assert_counts 3 4 4 "source-content change"

printf '// source b\n' > "$fixture/lib/TerminalCore/Sources/TerminalCore/B.swift"
run_wrapper
assert_counts 4 5 5 "source addition"

mv "$fixture/lib/TerminalCore/Sources/TerminalCore/B.swift" \
    "$fixture/lib/TerminalCore/Sources/TerminalCore/Renamed.swift"
run_wrapper
assert_counts 5 6 6 "source-path change"

rm "$fixture/lib/TerminalCore/Sources/TerminalCore/Renamed.swift"
run_wrapper
assert_counts 6 7 7 "source removal"

old_stamp="$(cat "$stamp")"
printf '// failing input\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
touch "$swift_fail"
set +e
run_wrapper
status=$?
set -e
[[ "$status" == 17 ]] || fail "failed test status was not preserved"
assert_counts 7 8 7 "failed run: parallel-lane failure must stop before the census lane"
[[ "$(cat "$stamp")" == "$old_stamp" ]] || fail "failed run published a fingerprint"

rm "$swift_fail"
run_wrapper
assert_counts 8 9 8 "run after failure"

old_stamp="$(cat "$stamp")"
printf '// hanging input\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
touch "$swift_hang"
export DANTERM_PTY_TEST_TIMEOUT_SECONDS=1
set +e
run_wrapper >"$TMP/timeout.out" 2>&1
status=$?
set -e
[[ "$status" == 124 ]] || fail "timed-out test returned $status instead of 124"
grep -q 'TerminalPTY test lane exceeded 1s' "$TMP/timeout.out" \
    || fail "timed-out test did not explain its deadline"
hang_pid="$(cat "$swift_hang_pid")"
if kill -0 "$hang_pid" 2>/dev/null; then
    fail "timed-out test left its Swift process running"
fi
assert_counts 9 10 8 "timed-out run: parallel-lane timeout must stop before the census lane"
[[ "$(cat "$stamp")" == "$old_stamp" ]] || fail "timed-out run published a fingerprint"
unset DANTERM_PTY_TEST_TIMEOUT_SECONDS
rm "$swift_hang"

run_wrapper
assert_counts 10 11 9 "run after timeout"

clean_fixture="$TMP/clean-repo"
mkdir -p "$clean_fixture/scripts"
cp "$ROOT_DIR/justfile" "$clean_fixture/justfile"
git -C "$clean_fixture" init -q
owned_build_dirs=(
    .spm-build
    .build
    lib/DanTermProtocol/.build
    lib/DanTermCore/.build
    lib/DanTermSupport/.build
    lib/TerminalCore/.build
    lib/TerminalPTY/.build
)
for path in "${owned_build_dirs[@]}"; do
    mkdir -p "$clean_fixture/$path"
    touch "$clean_fixture/$path/artifact"
done
just --justfile "$clean_fixture/justfile" --working-directory "$clean_fixture" clean >/dev/null
for path in "${owned_build_dirs[@]}"; do
    [[ ! -e "$clean_fixture/$path" ]] || fail "just clean left $path behind"
done

echo "TerminalPTY test cache self-test passed"
