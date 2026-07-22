#!/usr/bin/env bash
# Fetches and runs the pinned esctest2 allowlist through DanTerm's real pane-session boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_ROOT="${DANTERM_PROTOCOL_PROBE_RUN_ROOT:-$REPO_ROOT/.build/terminal-protocol-probe-runs}"
SOURCE_ROOT="${DANTERM_PROTOCOL_PROBE_SOURCE_ROOT:-$REPO_ROOT/.build/terminal-protocol-probe-sources}"
ESCTEST_REVISION="${DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION:-664be3cf2c1e3f06bc93a8bafb48a0db83c607db}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$RUN_ROOT/$run_id"
mkdir -p "$run_dir" "$SOURCE_ROOT"
result="$run_dir/result.txt"

esctest_source="$SOURCE_ROOT/esctest2"
if [[ ! -d "$esctest_source/.git" ]]; then
    git clone https://github.com/ThomasDickey/esctest2.git "$esctest_source"
fi
git -C "$esctest_source" checkout --detach "$ESCTEST_REVISION" >/dev/null 2>&1
if git -C "$esctest_source" apply --unidiff-zero --check "$SCRIPT_DIR/esctest2-danterm.patch" 2>/dev/null; then
    git -C "$esctest_source" apply --unidiff-zero "$SCRIPT_DIR/esctest2-danterm.patch"
elif ! git -C "$esctest_source" apply --unidiff-zero --reverse --check "$SCRIPT_DIR/esctest2-danterm.patch" 2>/dev/null; then
    printf 'status=preflight-failed\nerror=esctest2 source has unexpected changes\n' > "$result"
    echo "terminal protocol probes: esctest2 source is not the pinned tree plus the DanTerm adapter" >&2
    exit 2
fi

allowlist="$SCRIPT_DIR/terminal-protocol-probes-allowlist.txt"
cases=()
while IFS= read -r probe_case; do
    cases+=("$probe_case")
done < <(grep -v '^[[:space:]]*#' "$allowlist" | grep -v '^[[:space:]]*$')
include="^($(IFS='|'; echo "${cases[*]}"))$"
{
    printf 'run_id=%s\n' "$run_id"
    printf 'os=%s\n' "$(sw_vers -productVersion 2>/dev/null || uname -sr)"
    printf 'arch=%s\n' "$(uname -m)"
    printf 'esctest2_revision=%s\n' "$ESCTEST_REVISION"
    printf 'selected_cases=%s\n' "${#cases[@]}"
} > "$run_dir/environment.txt"

swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --product TerminalProtocolProbeRunner
swift build --package-path "$REPO_ROOT/lib/TerminalPTY" --product PTYSessionBootstrap
runner="$REPO_ROOT/lib/TerminalPTY/.build/debug/TerminalProtocolProbeRunner"
bootstrap="$REPO_ROOT/lib/TerminalPTY/.build/debug/PTYSessionBootstrap"

set +e
DANTERM_PROTOCOL_PROBE_INCLUDE="$include" \
DANTERM_PROTOCOL_PROBE_EXPECTED_COUNT="${#cases[@]}" \
    "$runner" "$run_dir" "$bootstrap" "$esctest_source/esctest/esctest.py" \
    > "$run_dir/runner.stdout" 2> "$run_dir/runner.stderr"
runner_status=$?
set -e

if (( runner_status != 0 )); then
    printf 'status=failed\nrunner_status=%s\n' "$runner_status" > "$result"
    echo "terminal protocol probes: failed; artifacts: $run_dir" >&2
    exit 1
fi
for artifact in summary.txt recording.json ownership.txt esctest.log; do
    if [[ ! -f "$run_dir/$artifact" ]]; then
        printf 'status=failed\nerror=missing %s\n' "$artifact" > "$result"
        echo "terminal protocol probes: missing $artifact; artifacts: $run_dir" >&2
        exit 1
    fi
done
if ! grep -q '^status=passed$' "$run_dir/summary.txt"; then
    printf 'status=failed\nerror=probe summary failed\n' > "$result"
    echo "terminal protocol probes: probe failure; artifacts: $run_dir" >&2
    exit 1
fi
if ! grep -q '^pane_session=released$' "$run_dir/ownership.txt" ||
   ! grep -q '^child=reaped$' "$run_dir/ownership.txt"; then
    printf 'status=failed\nerror=incomplete cleanup\n' > "$result"
    echo "terminal protocol probes: incomplete cleanup; artifacts: $run_dir" >&2
    exit 1
fi
printf 'status=passed\n' > "$result"
echo "terminal protocol probes: all selected probes passed"
echo "artifacts: $run_dir"
