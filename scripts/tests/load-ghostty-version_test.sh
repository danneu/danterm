#!/usr/bin/env bash
# Self-test for scripts/load-ghostty-version.sh. The validator is the only
# parser allowed to trust PR-controlled .ghostty-version content before it
# enters build scripts or GitHub Actions env files.
set -euo pipefail
unset GITHUB_ENV

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/load-ghostty-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

write_input() {
    printf '%s' "$1" > "$TMP/.ghostty-version"
}

run_validator() {
    rm -f "$TMP/stdout" "$TMP/stderr"
    set +e
    GHOSTTY_VERSION_FILE="$TMP/.ghostty-version" "$VALIDATOR" >"$TMP/stdout" 2>"$TMP/stderr"
    status=$?
    set -e
    return "$status"
}

expect_accept() {
    local tag="$1"
    write_input "$tag"$'\n'
    if ! run_validator; then
        fail "expected accept for $tag; stderr: $(cat "$TMP/stderr")"
    fi
    printf '%s\n' "$tag" > "$TMP/expected"
    cmp -s "$TMP/expected" "$TMP/stdout" || fail "stdout did not exactly match accepted tag $tag"
    [ ! -s "$TMP/stderr" ] || fail "accept case wrote stderr for $tag"
}

expect_reject() {
    local input="$1"
    local label="$2"
    write_input "$input"
    if run_validator; then
        fail "expected reject for $label"
    fi
    [ ! -s "$TMP/stdout" ] || fail "reject case leaked stdout for $label"
    [ -s "$TMP/stderr" ] || fail "reject case wrote empty stderr for $label"
}

accept_cases=(
    "v1.3.0"
    "v0.0.0"
    "v10.20.30"
)

for tag in "${accept_cases[@]}"; do
    expect_accept "$tag"
done

expect_reject "v1.3.0; echo pwned" "shell metacharacters"
expect_reject $'v1.3.0\nMALICIOUS=1' "embedded newline"
expect_reject "" "empty file"
expect_reject "1.3.0" "missing v"
expect_reject "v1.3" "incomplete semver"
expect_reject "v1.3.0.0" "extra component"
expect_reject "v1.3.0 " "trailing space"
expect_reject " v1.3.0" "leading space"
expect_reject "v1.4.0-rc1" "prerelease tag"

echo "Ghostty version validator self-test passed (${#accept_cases[@]} accept, 9 reject)"
