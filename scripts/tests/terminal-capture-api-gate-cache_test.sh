#!/usr/bin/env bash
# Behavioral self-test for the terminal capture API gate's persistent build
# caches and accepted-fingerprint contract. Fake drivers expose every decision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/tests/terminal-capture-api-gate_test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fixture="$TMP/repo"
mkdir -p "$fixture/lib/TerminalCore/Sources/TerminalCore"
mkdir -p "$fixture/lib/TerminalPTY"
printf '// manifest\n' > "$fixture/lib/TerminalCore/Package.swift"
printf '// source a\n' > "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"

fake_swift="$TMP/swift"
cat > "$fake_swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >> "$DANTERM_TEST_SWIFT_LOG"
printf '\n' >> "$DANTERM_TEST_SWIFT_LOG"
if [[ "${1:-}" == "build" && -e "$DANTERM_TEST_BUILD_FAIL" ]]; then
    exit 17
fi
if [[ " $* " == *" --show-bin-path "* ]]; then
    previous=""
    for argument in "$@"; do
        if [[ "$previous" == "--build-path" ]]; then
            printf '%s/debug\n' "$argument"
            exit 0
        fi
        previous="$argument"
    done
    exit 19
fi
EOF
chmod +x "$fake_swift"

fake_xcrun="$TMP/xcrun"
cat > "$fake_xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >> "$DANTERM_TEST_XCRUN_LOG"
printf '\n' >> "$DANTERM_TEST_XCRUN_LOG"
if [[ -e "$DANTERM_TEST_PROBE_FAIL" ]]; then
    exit 18
fi
modules=""
source=""
previous=""
for argument in "$@"; do
    if [[ "$previous" == "-I" ]]; then
        modules="$argument"
    fi
    previous="$argument"
    [[ "$argument" == *.swift ]] && source="$argument"
done
if [[ "$source" != *public-probe.swift && "$modules" == *default* ]]; then
    exit 1
fi
EOF
chmod +x "$fake_xcrun"

swift_log="$TMP/swift.log"
xcrun_log="$TMP/xcrun.log"
build_fail="$TMP/build-fail"
probe_fail="$TMP/probe-fail"
export DANTERM_REPO_ROOT="$fixture"
export DANTERM_SWIFT="$fake_swift"
export DANTERM_XCRUN="$fake_xcrun"
export DANTERM_TEST_SWIFT_LOG="$swift_log"
export DANTERM_TEST_XCRUN_LOG="$xcrun_log"
export DANTERM_TEST_BUILD_FAIL="$build_fail"
export DANTERM_TEST_PROBE_FAIL="$probe_fail"

run_wrapper() {
    "$WRAPPER" >/dev/null
}

cache_root="$fixture/.build/terminal-capture-api-gate"
default_build="$cache_root/default"
characterization_build="$cache_root/characterization"
stamp="$cache_root/terminal-core.sha256"

mark_caches() {
    mkdir -p "$default_build" "$characterization_build"
    touch "$default_build/preserved" "$characterization_build/preserved"
}

assert_invalidated() {
    local label="$1"
    [[ ! -e "$default_build/preserved" ]] || fail "$label: default cache was preserved"
    [[ ! -e "$characterization_build/preserved" ]] \
        || fail "$label: characterization cache was preserved"
}

: > "$swift_log"
: > "$xcrun_log"
run_wrapper
[[ -s "$stamp" ]] || fail "successful first run did not publish a fingerprint"
grep -q "<--build-path><$default_build>" "$swift_log" \
    || fail "default build did not use its root .build cache"
grep -q "<--build-path><$characterization_build>" "$swift_log" \
    || fail "characterization build did not use its distinct root .build cache"
[[ "$(wc -l < "$xcrun_log" | tr -d ' ')" == 5 ]] \
    || fail "first run did not execute the public and four capture probes"

mark_caches
: > "$swift_log"
: > "$xcrun_log"
run_wrapper
[[ -e "$default_build/preserved" && -e "$characterization_build/preserved" ]] \
    || fail "warm run did not preserve both build caches"
grep -q "<--build-path><$default_build>" "$swift_log" \
    || fail "warm run did not validate the default configuration"
grep -q "<--build-path><$characterization_build>" "$swift_log" \
    || fail "warm run did not validate the characterization configuration"
[[ "$(wc -l < "$xcrun_log" | tr -d ' ')" == 5 ]] \
    || fail "warm run skipped compiler probes"

mark_caches
printf '// manifest changed\n' >> "$fixture/lib/TerminalCore/Package.swift"
run_wrapper
assert_invalidated "manifest content change"

mark_caches
printf '// source changed\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
run_wrapper
assert_invalidated "source content change"

mark_caches
printf '// source b\n' > "$fixture/lib/TerminalCore/Sources/TerminalCore/B.swift"
run_wrapper
assert_invalidated "source addition"

mark_caches
mv "$fixture/lib/TerminalCore/Sources/TerminalCore/B.swift" \
    "$fixture/lib/TerminalCore/Sources/TerminalCore/Renamed.swift"
run_wrapper
assert_invalidated "source rename"

mark_caches
rm "$fixture/lib/TerminalCore/Sources/TerminalCore/Renamed.swift"
run_wrapper
assert_invalidated "source deletion"

old_stamp="$(cat "$stamp")"
mark_caches
printf '// failing build input\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
touch "$build_fail"
set +e
run_wrapper 2>/dev/null
status=$?
set -e
[[ "$status" == 17 ]] || fail "failed build status was not preserved"
assert_invalidated "failed build"
[[ "$(cat "$stamp")" == "$old_stamp" ]] || fail "failed build published a fingerprint"

rm "$build_fail"
run_wrapper
old_stamp="$(cat "$stamp")"
mark_caches
printf '// failing probe input\n' >> "$fixture/lib/TerminalCore/Sources/TerminalCore/A.swift"
touch "$probe_fail"
set +e
run_wrapper 2>/dev/null
status=$?
set -e
[[ "$status" != 0 ]] || fail "failed probe unexpectedly passed"
assert_invalidated "failed probe"
[[ "$(cat "$stamp")" == "$old_stamp" ]] || fail "failed probe published a fingerprint"

echo "terminal capture API gate cache self-test passed"
