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

mkdir -p "$TMP/ready-bin" "$TMP/ready-runs"
for tool in fish fzf swift; do
    printf '#!/bin/sh\necho "%s test version"\n' "$tool" > "$TMP/ready-bin/$tool"
    chmod +x "$TMP/ready-bin/$tool"
done
fake_runner="$TMP/fake-runner"
cat > "$fake_runner" <<'EOF'
#!/bin/sh
run_dir=$1
test "$HOME" = "$run_dir/home" || exit 41
test "$DANTERM_WORKFLOW_SSH_CONFIG" = "$run_dir/ssh/config" || exit 42
for workflow in zsh bash fish ssh fzf more less; do
    mkdir -p "$run_dir/$workflow"
    printf 'status=passed\n' > "$run_dir/$workflow/result.txt"
    : > "$run_dir/$workflow/recording.json"
    : > "$run_dir/$workflow/snapshots.txt"
    : > "$run_dir/$workflow/semantic-events.txt"
    : > "$run_dir/$workflow/ownership.txt"
done
EOF
chmod +x "$fake_runner"

DANTERM_WORKFLOW_PATH="$TMP/ready-bin" \
DANTERM_WORKFLOW_RUN_ROOT="$TMP/ready-runs" \
DANTERM_WORKFLOW_RUNNER="$fake_runner" "$HARNESS" >/dev/null
ready_dir="$(find "$TMP/ready-runs" -mindepth 1 -maxdepth 1 -type d | head -1)"
grep -q '^status=passed$' "$ready_dir/result.txt" || fail "successful runner result was not preserved"
[[ -f "$ready_dir/ssh/config" ]] || fail "isolated SSH configuration was not created"
grep -q '^[[:space:]]*UserKnownHostsFile ' "$ready_dir/ssh/config" || fail "SSH config did not isolate known hosts"
for workflow in zsh bash fish ssh fzf more less; do
    grep -q '^status=passed$' "$ready_dir/$workflow/result.txt" || fail "$workflow result missing"
    [[ -f "$ready_dir/$workflow/recording.json" ]] || fail "$workflow recording missing"
    [[ -f "$ready_dir/$workflow/ownership.txt" ]] || fail "$workflow ownership census missing"
done

echo "Terminal workflow harness contract tests passed"
