#!/usr/bin/env bash
# Behavioral tests for the terminal-characterization harness's safety and fixture helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS="$SCRIPT_DIR/terminal-characterization.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "terminal-characterization-harness_test: $*" >&2
    exit 1
}

# Intent: the app-control opt-in is checked before any build command can run.
# Why it exists: the characterization suite must not build, launch, or terminate
#   an application merely because a developer invoked the recipe by accident.
# Scenario: a developer runs the script without the explicit safety variable.
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/swift" <<EOF
#!/usr/bin/env bash
touch "$TEST_ROOT/swift-ran"
exit 99
EOF
chmod +x "$fake_bin/swift"
if PATH="$fake_bin:/usr/bin:/bin" "$HARNESS" >"$TEST_ROOT/no-opt-in.out" 2>"$TEST_ROOT/no-opt-in.err"; then
    fail "script succeeded without app-control opt-in"
else
    status=$?
fi
[[ $status -eq 2 ]] || fail "missing opt-in exited $status instead of 2"
[[ ! -e "$TEST_ROOT/swift-ran" ]] || fail "build command ran before opt-in check"
grep -qF 'DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1' "$TEST_ROOT/no-opt-in.err" \
    || fail "missing opt-in diagnostic omitted the required variable"

# shellcheck source=../terminal-characterization.sh
source "$HARNESS"

owned_root="$TEST_ROOT/run"
mkdir -p "$owned_root/child"
path_is_within "$owned_root" "$owned_root/child/file" \
    || fail "owned descendant was rejected"
if path_is_within "$owned_root" "$TEST_ROOT/run-sibling/file"; then
    fail "prefix-sharing sibling was accepted as owned"
fi

probe="$TEST_ROOT/probe.json"
cat >"$probe" <<EOF
{
  "home": "$owned_root/home",
  "applicationSupport": "$owned_root/home/Library/Application Support",
  "caches": "$owned_root/home/Library/Caches",
  "temporary": "$owned_root/tmp/",
  "config": "$owned_root/home/.config/danterm/config",
  "recovery": "$owned_root/home/Library/Application Support/com.danneu.danterm-terminal-characterization/Recovery",
  "socket": "$owned_root/home/Library/Caches/com.danneu.danterm-terminal-characterization/control.sock",
  "replay": "$owned_root/tmp/danterm-scrollback"
}
EOF
assert_probe_paths "$probe" "$owned_root" \
    || fail "valid isolated Foundation paths were rejected"
jq --arg outside "$TEST_ROOT/outside/control.sock" '.socket = $outside' "$probe" >"$TEST_ROOT/bad-probe.json"
if assert_probe_paths "$TEST_ROOT/bad-probe.json" "$owned_root" 2>/dev/null; then
    fail "socket outside the run-owned root was accepted"
fi

expected="$TEST_ROOT/expected.txt"
actual="$TEST_ROOT/actual.txt"
failure_dir="$TEST_ROOT/failures"
printf 'line with spaces  \nfinal' >"$expected"
printf 'line with spaces \nfinal\n' >"$actual"
expected_before="$(shasum -a 256 "$expected")"
if assert_fixture "$expected" "$actual" "narrow/viewport.txt" "$failure_dir" \
    >"$TEST_ROOT/compare.out" 2>"$TEST_ROOT/compare.err"; then
    fail "mismatched fixture passed"
fi
[[ "$(shasum -a 256 "$expected")" == "$expected_before" ]] \
    || fail "mismatch overwrote the checked-in expectation"
cmp -s "$actual" "$failure_dir/narrow/viewport.txt.actual" \
    || fail "mismatch did not preserve the exact actual bytes"
grep -qF 'line with spaces $' "$TEST_ROOT/compare.err" \
    || fail "mismatch diagnostic did not expose invisible whitespace"

cp "$expected" "$actual"
assert_fixture "$expected" "$actual" "matching.txt" "$failure_dir" \
    || fail "byte-identical fixture failed"
[[ ! -e "$failure_dir/matching.txt.actual" ]] \
    || fail "matching fixture left a failure artifact"

sleep 30 &
owned_pid=$!
sleep 30 &
unrelated_pid=$!
terminate_owned_pid "$owned_pid"
if kill -0 "$owned_pid" 2>/dev/null; then
    fail "owned process survived cleanup"
fi
if ! kill -0 "$unrelated_pid" 2>/dev/null; then
    fail "cleanup terminated an unrelated process"
fi
kill "$unrelated_pid"
wait "$unrelated_pid" 2>/dev/null || true

cleanup_root="$TEST_ROOT/cleanup-run"
mkdir -p "$cleanup_root"
touch "$cleanup_root/.danterm-terminal-characterization-run"
remove_owned_run_root "$cleanup_root" \
    || fail "marked run root was not removed"
[[ ! -e "$cleanup_root" ]] || fail "marked run root survived cleanup"

unmarked_root="$TEST_ROOT/unmarked-run"
mkdir -p "$unmarked_root"
if remove_owned_run_root "$unmarked_root" 2>/dev/null; then
    fail "cleanup accepted a run root without its ownership marker"
fi
[[ -d "$unmarked_root" ]] || fail "cleanup removed an unmarked directory"

echo "terminal characterization harness tests passed"
