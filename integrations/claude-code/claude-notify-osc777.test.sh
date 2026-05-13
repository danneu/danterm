#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/claude-notify-osc777.sh"
HOOK=${HOOK_UNDER_TEST:-$SOURCE_SCRIPT}
TOTAL=13
passed=0
failed=0

require_command() {
  local name=$1

  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$name" >&2
    exit 1
  fi
}

require_command cmp
require_command find
require_command jq

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Run the hook and capture output bytes via the CLAUDE_NOTIFY_TTY seam.
# tmux_mode is "set" or "unset" -- controls whether $TMUX is exported.
run_hook() {
  local out=$1
  local input=$2
  local tmux_mode=$3

  if [ "$tmux_mode" = "set" ]; then
    TMUX=/tmp/fake-tmux CLAUDE_NOTIFY_TTY="$out" "$HOOK" <<<"$input"
  else
    env -u TMUX CLAUDE_NOTIFY_TTY="$out" "$HOOK" <<<"$input"
  fi
}

check_case() {
  local name=$1
  local input=$2
  local tmux_mode=$3
  local expected=$4

  local out
  out=$(mktemp -p "$TMPROOT")

  if ! run_hook "$out" "$input" "$tmux_mode"; then
    printf 'FAIL: %s (hook exited non-zero)\n' "$name" >&2
    failed=$((failed + 1))
    return
  fi

  if cmp -s <(printf '%s' "$expected") "$out"; then
    passed=$((passed + 1))
    return
  fi

  printf 'FAIL: %s\n' "$name" >&2
  printf 'expected bytes:\n' >&2
  printf '%s' "$expected" | od -c >&2
  printf 'actual bytes:\n' >&2
  od -c < "$out" >&2
  failed=$((failed + 1))
}

write_success_ps_shim() {
  local shimbin=$1
  local hook_parent_pid=$2
  local tty_name=$3
  local ps_shim="$shimbin/ps"

  cat > "$ps_shim" <<EOF
#!/usr/bin/env bash
set -u

format=
pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      format=\$2
      shift 2
      ;;
    -p)
      pid=\$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "\$format:\$pid" in
  tty=:$hook_parent_pid)
    printf '?\n'
    ;;
  ppid=:$hook_parent_pid)
    printf '4242\n'
    ;;
  tty=:4242)
    printf '$tty_name\n'
    ;;
  ppid=:4242)
    printf '1\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$ps_shim"
}

write_skip_ps_shim() {
  local shimbin=$1
  local hook_parent_pid=$2
  local ps_shim="$shimbin/ps"

  cat > "$ps_shim" <<EOF
#!/usr/bin/env bash
set -u

format=
pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      format=\$2
      shift 2
      ;;
    -p)
      pid=\$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "\$format:\$pid" in
  tty=:*)
    printf '?\n'
    ;;
  ppid=:$hook_parent_pid)
    printf '4242\n'
    ;;
  ppid=:4242)
    printf '4000\n'
    ;;
  ppid=:4000)
    printf '1\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$ps_shim"
}

run_hook_with_walker() {
  local input=$1
  local tmux_mode=$2
  local devdir=$3
  local shimbin=$4

  if [ "$tmux_mode" = "set" ]; then
    TMUX=/tmp/fake-tmux CLAUDE_NOTIFY_DEV_DIR="$devdir" PATH="$shimbin:$PATH" \
      env -u CLAUDE_NOTIFY_TTY "$HOOK" <<<"$input"
  else
    CLAUDE_NOTIFY_DEV_DIR="$devdir" PATH="$shimbin:$PATH" \
      env -u TMUX -u CLAUDE_NOTIFY_TTY "$HOOK" <<<"$input"
  fi
}

check_walker_success_case() {
  local name=$1
  local tmux_mode=$2
  local tty_name=$3
  local expected=$4

  local case_root shimbin devdir out out_dir
  case_root=$(mktemp -d -p "$TMPROOT")
  shimbin="$case_root/shimbin"
  devdir="$case_root/devshim"
  mkdir "$shimbin" "$devdir"
  write_success_ps_shim "$shimbin" "$$" "$tty_name"

  out="$devdir/$tty_name"
  out_dir=$(dirname "$out")
  mkdir -p "$out_dir"
  if ! run_hook_with_walker '{"last_assistant_message":"walker"}' "$tmux_mode" "$devdir" "$shimbin"; then
    printf 'FAIL: %s (hook exited non-zero)\n' "$name" >&2
    failed=$((failed + 1))
    return
  fi

  if [ ! -f "$out" ]; then
    printf 'FAIL: %s (discovered tty output was not created)\n' "$name" >&2
    failed=$((failed + 1))
    return
  fi

  if cmp -s <(printf '%s' "$expected") "$out"; then
    passed=$((passed + 1))
    return
  fi

  printf 'FAIL: %s\n' "$name" >&2
  printf 'expected bytes:\n' >&2
  printf '%s' "$expected" | od -c >&2
  printf 'actual bytes:\n' >&2
  od -c < "$out" >&2
  failed=$((failed + 1))
}

check_walker_skip_case() {
  local name=$1

  local case_root shimbin devdir stderr created
  case_root=$(mktemp -d -p "$TMPROOT")
  shimbin="$case_root/shimbin"
  devdir="$case_root/devshim"
  stderr="$case_root/stderr"
  mkdir "$shimbin" "$devdir"
  write_skip_ps_shim "$shimbin" "$$"

  if ! run_hook_with_walker '{"last_assistant_message":"walker"}' "unset" "$devdir" "$shimbin" 2>"$stderr"; then
    printf 'FAIL: %s (hook exited non-zero)\n' "$name" >&2
    failed=$((failed + 1))
    return
  fi

  if [ -s "$stderr" ]; then
    printf 'FAIL: %s (stderr was not empty)\n' "$name" >&2
    cat "$stderr" >&2
    failed=$((failed + 1))
    return
  fi

  created=$(find "$devdir" -type f -print -quit)
  if [ -n "$created" ]; then
    printf 'FAIL: %s (unexpected output file: %s)\n' "$name" "$created" >&2
    failed=$((failed + 1))
    return
  fi

  passed=$((passed + 1))
}

check_nonfatal_write_case() {
  local name=$1
  local tmux_mode=$2

  local case_root tty_dir stderr
  case_root=$(mktemp -d -p "$TMPROOT")
  tty_dir="$case_root/not-a-tty-file"
  stderr="$case_root/stderr"
  mkdir "$tty_dir"

  if [ "$tmux_mode" = "set" ]; then
    TMUX=/tmp/fake-tmux CLAUDE_NOTIFY_TTY="$tty_dir" "$HOOK" \
      <<<'{"last_assistant_message":"late tty"}' 2>"$stderr"
  else
    env -u TMUX CLAUDE_NOTIFY_TTY="$tty_dir" "$HOOK" \
      <<<'{"last_assistant_message":"late tty"}' 2>"$stderr"
  fi

  if [ $? -ne 0 ]; then
    printf 'FAIL: %s (hook exited non-zero)\n' "$name" >&2
    failed=$((failed + 1))
    return
  fi

  if [ -s "$stderr" ]; then
    printf 'FAIL: %s (stderr was not empty)\n' "$name" >&2
    cat "$stderr" >&2
    failed=$((failed + 1))
    return
  fi

  passed=$((passed + 1))
}

# Build the OSC 777 byte string for a given pre-sanitized message.
# These format strings exactly mirror the hook's two printf calls.
expected_plain() {
  printf '\e]777;notify;Claude Code;%s\a' "$1"
}

expected_tmux() {
  # shellcheck disable=SC1003
  printf '\ePtmux;\e\e]777;notify;Claude Code;%s\a\e\\' "$1"
}

# Case 1: plain (no $TMUX), simple message
check_case "plain hello" \
  '{"last_assistant_message":"hello"}' \
  "unset" \
  "$(expected_plain hello)"

# Case 2: tmux ($TMUX set) -> DCS-wrapped output
check_case "tmux hello" \
  '{"last_assistant_message":"hello"}' \
  "set" \
  "$(expected_tmux hello)"

# Case 3a: plain, fallback message (no last_assistant_message field)
check_case "plain fallback" \
  '{}' \
  "unset" \
  "$(expected_plain 'Claude finished responding')"

# Case 3b: tmux, fallback message
check_case "tmux fallback" \
  '{}' \
  "set" \
  "$(expected_tmux 'Claude finished responding')"

# Case 4: sanitization. The fixture's JSON value of last_assistant_message
# must contain real ESC (0x1B) and BEL (0x07) bytes after JSON decoding so
# the script's tr stage actually has something to strip. Construct the
# JSON via jq from a printf-generated raw byte sequence -- jq encodes
# control bytes as the canonical six-character \u00XX form when
# emitting JSON, so the fixture text on the wire is exactly that, and
# this test source stays free of literal control bytes.
msg_with_controls=$(printf 'hi\033]9;evil\007there')
sanitize_fixture=$(jq -c -n --arg msg "$msg_with_controls" '{last_assistant_message: $msg}')

# Case 4a: plain branch, ESC + BEL stripped from payload
check_case "plain sanitization" \
  "$sanitize_fixture" \
  "unset" \
  "$(expected_plain 'hi]9;evilthere')"

# Case 4b: tmux branch, ESC + BEL stripped from payload
check_case "tmux sanitization" \
  "$sanitize_fixture" \
  "set" \
  "$(expected_tmux 'hi]9;evilthere')"

# Case 5: Stop hooks inside Claude Code subagents should be ignored.
check_case "subagent ignored" \
  '{"agent_id":"agent-1","last_assistant_message":"subagent done"}' \
  "unset" \
  ""

# Case 6a: walker skips a tty-less immediate parent and discovers a
# macOS-style ancestor tty.
check_walker_success_case "walker plain" \
  "unset" \
  "ttys999" \
  "$(expected_plain walker)"

# Case 6b: discovered tty still receives the tmux DCS-wrapped OSC.
check_walker_success_case "walker tmux" \
  "set" \
  "ttys999" \
  "$(expected_tmux walker)"

# Case 6c: Linux-style pts paths create output under the pts subdirectory.
check_walker_success_case "walker linux pts" \
  "unset" \
  "pts/9" \
  "$(expected_plain walker)"

# Case 7: no ancestor with a tty -> silent success and no notification.
check_walker_skip_case "walker silent skip"

# Case 8a: if the plain branch loses the tty before writing, exit silently.
check_nonfatal_write_case "plain nonfatal write" \
  "unset"

# Case 8b: if the tmux branch loses the tty before writing, exit silently.
check_nonfatal_write_case "tmux nonfatal write" \
  "set"

if [[ $failed -eq 0 ]]; then
  printf 'OK: %s/%s cases passed.\n' "$passed" "$TOTAL"
  exit 0
fi

printf 'FAILED: %s/%s cases passed, %s failed.\n' "$passed" "$TOTAL" "$failed" >&2
exit 1
