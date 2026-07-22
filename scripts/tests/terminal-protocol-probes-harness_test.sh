#!/usr/bin/env bash
# Contract tests for result parsing, diagnostic retention, timeout failure, and cleanup evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT_DIR/scripts/terminal-protocol-probes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

source_root="$TMP/source"
mkdir -p "$source_root/esctest2/esctest" "$TMP/runs"
git -C "$source_root/esctest2" init -q
git -C "$source_root/esctest2" config user.email probe@example.invalid
git -C "$source_root/esctest2" config user.name Probe
cat > "$source_root/esctest2/esctest/escutil.py" <<'EOF'
def GetCursorPosition():
  return Point(1, 1)

def GetScreenSize():
  """Return the terminal's screen-size in characters.

  The size is reported for the terminal's character-cell window,
  which is smaller than the shell-window."""
  esccmd.XTERM_WINOPS(esccmd.WINOP_REPORT_TEXT_AREA_CHARS)
  params = escio.ReadCSI("t")
  return Size(params[2], params[1])

def GetDisplaySize():
  return Size(80, 24)
EOF
: > "$source_root/esctest2/esctest/esctest.py"
git -C "$source_root/esctest2" add esctest
git -C "$source_root/esctest2" commit -qm fixture
revision="$(git -C "$source_root/esctest2" rev-parse HEAD)"

fake_runner="$TMP/fake-runner"
cat > "$fake_runner" <<'EOF'
#!/bin/sh
run_dir=$1
case "${FAKE_OUTCOME:-pass}" in
    pass) status=passed ;;
    probe-fail) status=failed ;;
    timeout)
        printf 'pane_session=released\nchild=reaped\npty_owner=released\n' > "$run_dir/ownership.txt"
        exit 124
        ;;
esac
printf 'status=%s\nselected=11\npassed=11\nfailed=0\n' "$status" > "$run_dir/summary.txt"
: > "$run_dir/recording.json"
: > "$run_dir/esctest.log"
printf 'pane_session=released\nchild=reaped\npty_owner=released\n' > "$run_dir/ownership.txt"
EOF
chmod +x "$fake_runner"

run_harness() {
    DANTERM_PROTOCOL_PROBE_SOURCE_ROOT="$source_root" \
    DANTERM_PROTOCOL_PROBE_RUN_ROOT="$TMP/runs" \
    DANTERM_PROTOCOL_PROBE_RUNNER="$fake_runner" \
    "$HARNESS" >/dev/null
}

DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION="$revision" run_harness || fail "valid probe result failed"

set +e
FAKE_OUTCOME=probe-fail DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION="$revision" run_harness
probe_status=$?
FAKE_OUTCOME=timeout DANTERM_PROTOCOL_PROBE_ESCTEST_REVISION="$revision" run_harness
timeout_status=$?
set -e
[[ "$probe_status" == 1 ]] || fail "intentionally failing probe passed"
[[ "$timeout_status" == 1 ]] || fail "timeout result passed"

latest="$(find "$TMP/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
[[ -f "$latest/result.txt" ]] || fail "failure did not retain a result artifact"
grep -q '^child=reaped$' "$latest/ownership.txt" || fail "timeout did not retain cleanup evidence"

echo "Terminal protocol probe harness contract tests passed"
