#!/usr/bin/env bash
# Creates an isolated, durable run directory before launching the opt-in real-PTY workflows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_ROOT="${DANTERM_WORKFLOW_RUN_ROOT:-$REPO_ROOT/.build/terminal-workflow-runs}"
WORKFLOW_PATH="${DANTERM_WORKFLOW_PATH:-$PATH}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$RUN_ROOT/$run_id"
mkdir -p "$run_dir"

manifest="$run_dir/environment.txt"
result="$run_dir/result.txt"
{
    printf 'run_id=%s\n' "$run_id"
    printf 'os=%s\n' "$(sw_vers -productVersion 2>/dev/null || uname -sr)"
    printf 'arch=%s\n' "$(uname -m)"
} > "$manifest"

missing=()
for tool in fish fzf swift; do
    path="$(PATH="$WORKFLOW_PATH" command -v "$tool" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
        missing+=("$tool")
        continue
    fi
    printf '%s_path=%s\n' "$tool" "$path" >> "$manifest"
    printf '%s_version=%s\n' "$tool" "$(PATH="$WORKFLOW_PATH" "$path" --version 2>&1 | head -1)" >> "$manifest"
done
for tool in /bin/zsh /bin/bash /usr/bin/ssh /usr/sbin/sshd /usr/bin/more /usr/bin/less; do
    name="${tool##*/}"
    if [[ ! -x "$tool" ]]; then
        missing+=("$tool")
        continue
    fi
    printf '%s_path=%s\n' "$name" "$tool" >> "$manifest"
    printf '%s_version=%s\n' "$name" "$("$tool" --version 2>&1 | head -1 || true)" >> "$manifest"
done

if (( ${#missing[@]} > 0 )); then
    printf 'status=preflight-failed\nmissing=%s\n' "${missing[*]}" > "$result"
    echo "terminal workflows: missing prerequisites: ${missing[*]}" >&2
    echo "artifacts: $run_dir" >&2
    exit 2
fi

printf 'status=ready\n' > "$result"
echo "terminal workflows: harness ready; workflow cases land in commit 2"
echo "artifacts: $run_dir"
