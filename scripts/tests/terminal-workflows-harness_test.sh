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
grep -q '^ssh_version=OpenSSH_' "$run_dir/environment.txt" || fail "OpenSSH version was not recorded"

mkdir -p "$TMP/ready-bin" "$TMP/ready-runs"
for tool in fish fzf swift asciinema; do
    printf '#!/bin/sh\necho "%s test version"\n' "$tool" > "$TMP/ready-bin/$tool"
    chmod +x "$TMP/ready-bin/$tool"
done
printf '#!/bin/sh\n' > "$TMP/ready-bin/asciinema"
chmod +x "$TMP/ready-bin/asciinema"
set +e
DANTERM_WORKFLOW_PATH="$TMP/ready-bin" DANTERM_WORKFLOW_RUN_ROOT="$TMP/runs" "$HARNESS" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 2 ]] || fail "empty asciinema version did not refuse with status 2"
printf '#!/bin/sh\necho "asciinema test version"\n' > "$TMP/ready-bin/asciinema"
fake_runner="$TMP/fake-runner"
cat > "$fake_runner" <<'EOF'
#!/bin/sh
run_dir=$1
test "$HOME" = "$run_dir/home" || exit 41
test "$DANTERM_WORKFLOW_SSH_CONFIG" = "$run_dir/ssh/config" || exit 42
for workflow in zsh bash fish ssh fzf more less asciinema; do
    mkdir -p "$run_dir/$workflow"
    printf 'status=passed\n' > "$run_dir/$workflow/result.txt"
    : > "$run_dir/$workflow/recording.json"
    : > "$run_dir/$workflow/snapshots.txt"
    : > "$run_dir/$workflow/semantic-events.txt"
    : > "$run_dir/$workflow/ownership.txt"
done
printf '{"version":2,"width":80,"height":24,"env":{"SHELL":"/bin/zsh","TERM":"xterm-256color"}}\n' > "$run_dir/asciinema/session.cast"
printf 'status=passed\n' > "$run_dir/asciinema/cast-validation.txt"
EOF
chmod +x "$fake_runner"

missing_runner="$TMP/missing-runner"
printf '#!/bin/sh\nexit 0\n' > "$missing_runner"
chmod +x "$missing_runner"
set +e
DANTERM_WORKFLOW_PATH="$TMP/ready-bin" DANTERM_WORKFLOW_RUN_ROOT="$TMP/runs" DANTERM_WORKFLOW_RUNNER="$missing_runner" "$HARNESS" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 1 ]] || fail "missing workflow artifacts did not fail"

DANTERM_WORKFLOW_PATH="$TMP/ready-bin" \
DANTERM_WORKFLOW_RUN_ROOT="$TMP/ready-runs" \
DANTERM_WORKFLOW_RUNNER="$fake_runner" "$HARNESS" >/dev/null
ready_dir="$(find "$TMP/ready-runs" -mindepth 1 -maxdepth 1 -type d | head -1)"
grep -q '^status=passed$' "$ready_dir/result.txt" || fail "successful runner result was not preserved"
grep -q '^asciinema_version=asciinema test version$' "$ready_dir/environment.txt" || fail "asciinema version was not recorded"
[[ -f "$ready_dir/ssh/config" ]] || fail "isolated SSH configuration was not created"
grep -q '^[[:space:]]*UserKnownHostsFile ' "$ready_dir/ssh/config" || fail "SSH config did not isolate known hosts"
for workflow in zsh bash fish ssh fzf more less asciinema; do
    grep -q '^status=passed$' "$ready_dir/$workflow/result.txt" || fail "$workflow result missing"
    [[ -f "$ready_dir/$workflow/recording.json" ]] || fail "$workflow recording missing"
    [[ -f "$ready_dir/$workflow/ownership.txt" ]] || fail "$workflow ownership census missing"
done
[[ -f "$ready_dir/asciinema/session.cast" ]] || fail "asciinema cast missing"
grep -q '^status=passed$' "$ready_dir/asciinema/cast-validation.txt" || fail "cast validation report missing"

echo "Terminal workflow harness contract tests passed"
