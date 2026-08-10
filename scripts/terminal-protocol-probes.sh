#!/usr/bin/env bash
# Fetches and runs pinned esctest2 and vttest probes through DanTerm's real pane-session boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${DANTERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_ROOT="${DANTERM_PROTOCOL_PROBE_RUN_ROOT:-$REPO_ROOT/.build/terminal-protocol-probe-runs}"
SOURCE_ROOT="${DANTERM_PROTOCOL_PROBE_SOURCE_ROOT:-$REPO_ROOT/.build/terminal-protocol-probe-sources}"
BUILD_ROOT="${DANTERM_PROTOCOL_PROBE_BUILD_ROOT:-$REPO_ROOT/.build/terminal-protocol-probe-builds}"
ESCTEST_REVISION="${DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION:-664be3cf2c1e3f06bc93a8bafb48a0db83c607db}"
VTTEST_REVISION="${DANTERM_PROTOCOL_PROBE_VTTEST_REVISION:-0229d7171a8574a2bf406c6ce14549f65d810e51}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$RUN_ROOT/$run_id"
mkdir -p "$run_dir" "$SOURCE_ROOT" "$BUILD_ROOT"
result="$run_dir/result.txt"

esctest_source="$SOURCE_ROOT/esctest2"
if [[ ! -d "$esctest_source/.git" ]]; then
    git clone https://github.com/ThomasDickey/esctest2.git "$esctest_source"
fi

vttest_source="$SOURCE_ROOT/vttest"
if [[ ! -d "$vttest_source/.git" ]]; then
    git clone https://github.com/ThomasDickey/vttest-snapshots.git "$vttest_source"
fi
git -C "$vttest_source" checkout --detach "$VTTEST_REVISION" >/dev/null 2>&1
if ! git -C "$vttest_source" diff --quiet HEAD --; then
    printf 'status=preflight-failed\nerror=vttest source has tracked changes\n' > "$result"
    echo "terminal protocol probes: vttest source is not the pinned tree" >&2
    exit 2
fi
vttest_build="$BUILD_ROOT/vttest-$VTTEST_REVISION"
mkdir -p "$vttest_build"
if [[ ! -f "$vttest_build/makefile" ]]; then
    (cd "$vttest_build" && "$vttest_source/configure" --quiet)
fi
make -C "$vttest_build" vttest >/dev/null
vttest="$vttest_build/vttest"
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
    printf 'esctest2_selected_cases=%s\n' "${#cases[@]}"
    printf 'vttest_revision=%s\n' "$VTTEST_REVISION"
    printf 'vttest_sessions=%s\n' '3'
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

vttest_root="$run_dir/vttest"
mkdir -p "$vttest_root"
cp "$vttest_source/COPYING" "$vttest_root/COPYING.vttest"

run_vttest_session() {
    local session="$1"
    local replay="$SCRIPT_DIR/vttest-replays/$session.log"
    local session_dir="$vttest_root/$session"
    mkdir -p "$session_dir"

    set +e
    DANTERM_VTTEST_SESSION="$session" \
        "$runner" "$session_dir" "$bootstrap" "$vttest" "$replay" \
        > "$session_dir/runner.stdout" 2> "$session_dir/runner.stderr"
    local status=$?
    set -e

    if (( status != 0 )); then
        printf 'status=failed\nerror=vttest session %s failed\nrunner_status=%s\n' "$session" "$status" > "$result"
        echo "terminal protocol probes: vttest $session failed; artifacts: $session_dir" >&2
        exit 1
    fi
    for artifact in summary.txt recording.json ownership.txt vttest.log; do
        if [[ ! -f "$session_dir/$artifact" ]]; then
            printf 'status=failed\nerror=vttest session %s missing %s\n' "$session" "$artifact" > "$result"
            echo "terminal protocol probes: vttest $session missing $artifact; artifacts: $session_dir" >&2
            exit 1
        fi
    done
    if ! grep -q '^status=passed$' "$session_dir/summary.txt" ||
       ! grep -q '^pane_session=released$' "$session_dir/ownership.txt" ||
       ! grep -q '^child=reaped$' "$session_dir/ownership.txt"; then
        printf 'status=failed\nerror=vttest session %s incomplete\n' "$session" > "$result"
        echo "terminal protocol probes: vttest $session incomplete; artifacts: $session_dir" >&2
        exit 1
    fi
}

run_vttest_session vt100-dsr-cpr
run_vttest_session vt100-da1
run_vttest_session vt320-deccpr

printf 'status=passed\n' > "$result"
echo "terminal protocol probes: esctest2 allowlist and vttest sessions passed"
echo "artifacts: $run_dir"
