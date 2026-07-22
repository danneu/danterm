#!/usr/bin/env bash
# Contract tests for workflow preflight refusal and failure artifact preservation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT_DIR/scripts/terminal-workflows.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/runs"
set +e
DANTERM_WORKFLOW_PATH="$TMP/bin" DANTERM_WORKFLOW_RUN_ROOT="$TMP/runs" "$HARNESS" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 2 ]] || fail "missing prerequisites did not refuse with status 2"
run_dir="$(find "$TMP/runs" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -f "$run_dir/environment.txt" ]] || fail "preflight failure did not preserve environment manifest"
[[ -f "$run_dir/result.txt" ]] || fail "preflight failure did not preserve result"
grep -q '^status=preflight-failed$' "$run_dir/result.txt" || fail "wrong failure classification"
grep -q '^zsh_path=/bin/zsh$' "$run_dir/environment.txt" || fail "system tool path was not recorded"
grep -q '^zsh_version=' "$run_dir/environment.txt" || fail "system tool version was not recorded"

echo "Terminal workflow harness contract tests passed"
