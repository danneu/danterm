#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/danterm-agent-session.sh"
HOOK=${HOOK_UNDER_TEST:-$SOURCE_SCRIPT}

passed=0
failed=0
TOTAL=0

check_case() {
  local name=$1 input=$2 expect_invocation=${3:-}
  TOTAL=$((TOTAL + 1))

  local tmpdir out status
  tmpdir=$(mktemp -d)
  out="$tmpdir/out"
  status=0

  if [ -n "$expect_invocation" ]; then
    cat >"$tmpdir/danterm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DANTERM_AGENT_STUB_LOG"
STUB
    chmod +x "$tmpdir/danterm"
  fi

  local old_path=${PATH:-}
  local old_log=${DANTERM_AGENT_STUB_LOG:-}
  local old_sock=${DANTERM_SOCK:-}
  local old_pane=${DANTERM_PANE:-}

  PATH="$tmpdir:$old_path"
  DANTERM_AGENT_STUB_LOG="$tmpdir/invocation"
  export PATH DANTERM_AGENT_STUB_LOG

  "$HOOK" <<<"$input" >"$out" 2>"$tmpdir/err" || status=$?

  PATH=$old_path
  if [ -n "$old_log" ]; then export DANTERM_AGENT_STUB_LOG="$old_log"; else unset DANTERM_AGENT_STUB_LOG; fi
  if [ -n "$old_sock" ]; then export DANTERM_SOCK="$old_sock"; else unset DANTERM_SOCK; fi
  if [ -n "$old_pane" ]; then export DANTERM_PANE="$old_pane"; else unset DANTERM_PANE; fi

  if [ "$status" -ne 0 ]; then
    printf 'FAIL: %s (hook exited %s)\n' "$name" "$status" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi
  if [ -s "$out" ]; then
    printf 'FAIL: %s (expected stdout silence)\n' "$name" >&2
    printf 'stdout: %s\n' "$(cat "$out")" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi
  if [ -n "$expect_invocation" ]; then
    if [ "$(cat "$tmpdir/invocation" 2>/dev/null)" != "$expect_invocation" ]; then
      printf 'FAIL: %s (wrong danterm invocation)\n' "$name" >&2
      printf 'expected: %s\n' "$expect_invocation" >&2
      printf 'actual: %s\n' "$(cat "$tmpdir/invocation" 2>/dev/null)" >&2
      failed=$((failed + 1))
      rm -rf "$tmpdir"
      return
    fi
  elif [ -s "$tmpdir/invocation" ]; then
    printf 'FAIL: %s (unexpected danterm invocation)\n' "$name" >&2
    failed=$((failed + 1))
    rm -rf "$tmpdir"
    return
  fi

  passed=$((passed + 1))
  rm -rf "$tmpdir"
}

export DANTERM_SOCK=/tmp/danterm.sock
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "session start attaches silently" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c-0000-4000-9000-abcdef123456"}' \
  'agent attach --kind claude --id 4f3a2b1c-0000-4000-9000-abcdef123456'

unset DANTERM_SOCK
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "missing socket is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'

export DANTERM_SOCK=/tmp/danterm.sock
unset DANTERM_PANE
check_case "missing pane is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'

export DANTERM_SOCK=/tmp/danterm.sock
export DANTERM_PANE=11111111-1111-4111-8111-111111111111
check_case "empty session id is silent no-op" \
  '{"hook_event_name":"SessionStart"}'

PATH=/usr/bin:/bin
export PATH
check_case "missing cli is silent no-op" \
  '{"hook_event_name":"SessionStart","session_id":"4f3a2b1c"}'

if [ "$failed" -eq 0 ]; then
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"
  exit 0
fi

printf 'FAILED: %s/%s passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
