#!/usr/bin/env bash
# Behavioral self-test for the gate's centralized disposable build-path policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLICY="$ROOT_DIR/scripts/build-path-policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "build-path-policy_test: $*" >&2
    exit 1
}

run_fixture() {
    local declarations="$1"
    DANTERM_BUILD_PATH_POLICY_INPUT="$declarations" "$POLICY"
}

valid="$TMP/valid"
cat >"$valid" <<EOF
gate-a	gate	$ROOT_DIR/.build-gate/a
gate-b	gate	$ROOT_DIR/.build-gate/b
package-default	implicit-default	$ROOT_DIR/lib/Example/.build
cold-build	throwaway	/private/tmp/cold-build
ios-app	app	$ROOT_DIR/.spm-build/ios-app/simulator
EOF
run_fixture "$valid" >/dev/null || fail "the policy rejected sanctioned paths"

outside="$TMP/outside"
printf 'bad\tgate\t%s/.build-other\n' "$ROOT_DIR" >"$outside"
if run_fixture "$outside" >"$TMP/out" 2>&1; then
    fail "the policy accepted a gate path outside .build-gate"
fi
grep -q "outside .*\.build-gate" "$TMP/out" \
    || fail "the outside-root failure did not explain the boundary"

root_default="$TMP/root-default"
printf 'bad\tgate\t%s/.build/private\n' "$ROOT_DIR" >"$root_default"
if run_fixture "$root_default" >"$TMP/out" 2>&1; then
    fail "the policy accepted an explicit gate path beneath .build"
fi

duplicate="$TMP/duplicate"
cat >"$duplicate" <<EOF
lane-a	gate	$ROOT_DIR/.build-gate/shared
lane-b	gate	$ROOT_DIR/.build-gate/shared
EOF
if run_fixture "$duplicate" >"$TMP/out" 2>&1; then
    fail "the policy accepted two lanes with one persistent path"
fi
grep -q "lane-a.*lane-b\|lane-b.*lane-a" "$TMP/out" \
    || fail "the duplicate failure did not name both lanes"

actual="$TMP/actual"
"$POLICY" --list >"$actual" || fail "the repository's build paths violate the policy"
for path in .build-gate/terminal-core-type-check .build-gate/root-app-tests \
    .build-gate/ios-portability/lib-TerminalCore .build-gate/bundle-layout-tool \
    .build-gate/terminal-capture-api/default .build-gate/terminal-capture-api/characterization \
    .spm-build/ios-app/simulator; do
    grep -q "$path" "$actual" || fail "the collector missed $path"
done

runner_steps="$TMP/runner-steps"
printf 'swift test --scratch-path %s/.build/private\n' "$ROOT_DIR" >"$runner_steps"
if RUN_TEST_SUITE_STEPS_FILE="$runner_steps" "$POLICY" >"$TMP/out" 2>&1; then
    fail "the collector missed an invalid path declared directly by a gate step"
fi

echo "build path policy tests passed"
