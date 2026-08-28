#!/usr/bin/env bash
# Smoke-test the bundled danterm CLI against an isolated development slot.
# gate: opt-out -- requires a GUI and jq; runs through just test-cli
set -Eeuo pipefail

# Name the failing line. Nearly every assertion here is a bare `[[ ... ]]`, which
# prints nothing at all when it fails, so without this the only symptom of a broken
# assertion is the script's exit status -- and finding which of four hundred lines
# produced it means re-running the whole slot-claiming script under `bash -x`.
# `-E` above is what carries this trap into the functions below.
trap 'echo "danterm-cli_test.sh: failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CLI_PATH="$SCRIPT_DIR/.build/DanTerm Dev.app/Contents/Helpers/danterm"
# Read the tape stream version from the constant the app reports, rather than keeping a
# copy of the number here. What this script can prove is that the running app agrees with
# the source tree it was built from; a literal proves only that someone edited two places
# at once, and this one sat at 3 while the constant reached 5.
TAPE_VERSION_SOURCE="$SCRIPT_DIR/lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeStream.swift"
tape_version="$(sed -n 's/^public let paneTapeStreamVersion = \([0-9][0-9]*\)$/\1/p' \
    "$TAPE_VERSION_SOURCE")"
if [[ ! "$tape_version" =~ ^[0-9]+$ ]]; then
    echo "could not read paneTapeStreamVersion from $TAPE_VERSION_SOURCE" >&2
    exit 1
fi
launch_output="$(mktemp)"
launch_error="$(mktemp)"
smoke_output="$(mktemp)"
smoke_error="$(mktemp)"
tape_output="$(mktemp)"
inspect_output="$(mktemp)"
snapshot_output="$(mktemp)"
tape_fixture="$(mktemp)"
# Holds socket paths that must never resolve, for the cases asserting the CLI
# ignores an ambient DANTERM_SOCK.
unusable_dir="$(mktemp -d)"
slot=""

# Returns this run's slot to the pool that every checkout on the machine shares.
#
# The launcher exits as soon as it prints its handle, so the app outlives it and no
# launcher death can free the slot -- only `--stop <slot>` can. Idempotent, because
# the normal path releases the slot mid-script to prove the app went away, and the
# EXIT trap then runs anyway.
release_slot() {
    [[ "$slot" =~ ^[0-9]+$ ]] || return 0
    local released="$slot"
    slot=""
    python3 "$SCRIPT_DIR/scripts/dev-slot-launcher.py" --stop "$released" >/dev/null 2>&1 || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    release_slot
    rm -f "$launch_output" "$launch_error" "$smoke_output" "$smoke_error" \
        "$tape_output" "$inspect_output" "$snapshot_output" "$tape_fixture"
    rm -rf "$unusable_dir"
    exit "$status"
}
trap cleanup EXIT INT TERM

# Run the launcher in the foreground. It stages the bundle, spawns the app, and waits
# for the control socket to accept a connection before it prints one JSON handle and
# exits -- so by the time it returns, the app behind the handle is already reachable
# and no poll loop here can improve on that.
if ! python3 "$SCRIPT_DIR/scripts/dev-slot-launcher.py" >"$launch_output" 2>"$launch_error"; then
    echo "DanTerm slot launcher failed" >&2
    cat "$launch_error" >&2
    exit 1
fi
handle="$(tail -1 "$launch_output")"
printf '%s\n' "$handle" | jq -e . >/dev/null 2>&1 || {
    echo "DanTerm slot launcher did not emit a handle" >&2
    cat "$launch_error" >&2
    exit 1
}
# Read the slot first: from here on a failure owns a slot that the trap must release.
slot="$(printf '%s\n' "$handle" | jq -er '.slot')"
socket="$(printf '%s\n' "$handle" | jq -er '.socketPath')"
bundle_id="$(printf '%s\n' "$handle" | jq -er '.bundleId')"
reported_pid="$(printf '%s\n' "$handle" | jq -er '.pid')"
[[ "$slot" -ge 1 && "$slot" -le 8 ]]
[[ "$bundle_id" == "com.danneu.danterm-dev.$slot" ]]
# The handle names the app, not the launcher, so the one thing to check is that the
# pid is live. Comparing it to the launcher's own pid could never hold.
kill -0 "$reported_pid"
[[ "$socket" == "$HOME/Library/Caches/$bundle_id/control.sock" ]]

# Asserts a string is absent from the given files.
#
# A leading `!` on a grep cannot assert this. `errexit` does not apply to a command
# whose status a `!` inverts, so all eleven lines written that way were no-ops: the
# string could appear and the script would carry on to report a pass.
refute() {
    local pattern="$1"
    shift
    if grep -qF "$pattern" "$@"; then
        echo "unexpected output: $pattern" >&2
        exit 1
    fi
}

# Runs the bundled helper and captures what a caller of the shell would see.
#
# Everything below that uses this runs against the bundle rather than the build
# products, which is the only thing this file can prove that the gate cannot. The
# usage and help text used to be asserted here too; it needs no app and no socket,
# so it lives in `cli-tests/UsageTextTests.swift` where `just test` runs it. This
# script is opt-in, and its copy of the invocation line sat stale for the whole
# life of the `--tcp` flag before anyone ran it.
out=$(mktemp); err=$(mktemp)
run_cli() {
    : >"$out"
    : >"$err"
    if "$CLI_PATH" "$@" >"$out" 2>"$err"; then
        status=0
    else
        status=$?
    fi
}

# `skill` is local-only and emits the canonical bundled skill bytes without
# consulting pane targeting or the control socket. Exercise the helper directly
# and through the shape installed on PATH.
export DANTERM_SOCK="$unusable_dir/unusable.sock"
run_cli skill
[[ $status -eq 0 ]]
[[ ! -s "$err" ]]
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" "$out"
# The cmp above only proves the bundle matches its source file, so it passes
# whatever the source says. These two check what the bundle teaches: every
# target is named behind a flag, and no subcommand shows a positional one.
grep -qF 'danterm pane focus --pane <pane-id>' "$out"
refute 'danterm pane focus <pane-id>' "$out"

skill_bin=$(mktemp -d)
ln -s "$CLI_PATH" "$skill_bin/danterm"
: >"$out"
: >"$err"
if PATH="$skill_bin:$PATH" danterm skill >"$out" 2>"$err"; then
    status=0
else
    status=$?
fi
[[ $status -eq 0 ]]
[[ ! -s "$err" ]]
cmp "$SCRIPT_DIR/integrations/danterm/SKILL.md" "$out"

run_cli skill extra
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unexpected argument: extra' "$err"
refute 'DanTerm is not running' "$out" "$err"
run_cli skill --bogus
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --bogus' "$err"
refute 'DanTerm is not running' "$out" "$err"

missing_bundle="$skill_bin/Missing.app"
mkdir -p "$missing_bundle/Contents/Helpers"
cp "$CLI_PATH" "$missing_bundle/Contents/Helpers/danterm"
: >"$out"
: >"$err"
if "$missing_bundle/Contents/Helpers/danterm" skill >"$out" 2>"$err"; then
    status=0
else
    status=$?
fi
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: bundled skill is missing or unreadable' "$err"
refute 'DanTerm is not running' "$out" "$err"
rm -rf "$skill_bin"

# `doctor` keeps its local checks available before the app launches; every
# instance-owned row skips without surfacing a socket error.
doctor_home=$(mktemp -d)
doctor_socket="$doctor_home/missing.sock"
run_doctor_with_temp_home() {
    : >"$out"
    : >"$err"
    if HOME="$doctor_home" CODEX_HOME="$doctor_home/.codex" "$CLI_PATH" "$@" >"$out" 2>"$err"; then
        status=0
    else
        status=$?
    fi
}
run_doctor_with_temp_home --socket "$doctor_socket" doctor
[[ $status -eq 0 ]]
[[ -s "$out" ]]
[[ ! -s "$err" ]]
grep -qF 'OK ' "$out"
grep -qF "SKIP Instance: $doctor_socket did not answer." "$out"
grep -qF 'SKIP Notifications: The instance did not answer, so this check is unavailable.' "$out"
grep -qF 'SKIP Full Disk Access: The instance did not answer, so this check is unavailable.' "$out"
grep -qF 'SKIP Developer Tools: The instance did not answer, so this check is unavailable.' "$out"
grep -qF 'SKIP Configured font installed: The instance did not answer, so this check is unavailable.' "$out"
refute 'DanTerm is not running' "$err"
run_doctor_with_temp_home --socket "$doctor_socket" doctor --json
[[ $status -eq 0 ]]
jq -e --arg target "$doctor_socket" \
    '.instance == {target: $target, answered: false} and (.checks | all(has("id")))' \
    "$out" >/dev/null
run_doctor_with_temp_home doctor --all
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --all' "$err"
refute 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor -v
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: -v' "$err"
refute 'DanTerm is not running' "$out" "$err"
run_doctor_with_temp_home doctor --bogus
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: unknown flag: --bogus' "$err"
refute 'DanTerm is not running' "$out" "$err"
rm -rf "$doctor_home"

export DANTERM=1
export DANTERM_SOCK="$unusable_dir/wrong.sock"

slot_cli() {
    "$CLI_PATH" --socket "$socket" "$@"
}

model=""
pane_id=""
tab_id=""
group_id=""
for _ in $(seq 1 30); do
    if model="$(slot_cli ls 2>/dev/null)" \
        && tab_id="$(printf '%s\n' "$model" | jq -er '.selectedTabId // empty')" \
        && pane_id="$(printf '%s\n' "$model" | jq -er --arg tab "$tab_id" '.groups[].tabs[] | select(.id == $tab) | .focusedPaneId // empty')" \
        && group_id="$(printf '%s\n' "$model" | jq -er --arg tab "$tab_id" '.groups[] | select([.tabs[].id] | index($tab)) | .id')"; then
        break
    fi
    sleep 1
done
if [[ -z "$pane_id" || -z "$tab_id" || -z "$group_id" ]]; then
    echo "DanTerm model did not expose an active pane" >&2
    exit 1
fi

printf '%s\n' "$model" | jq .groups >/dev/null
export DANTERM_PANE="$pane_id"
# A tape is only worth asserting on once the shell in the pane has produced output, so
# poll for the first feed event rather than reading a tape that is legitimately empty.
for _ in $(seq 1 30); do
    slot_cli pane tape --pane "$pane_id" >"$tape_output"
    if jq -e -s '[.[] | select(.kind == "event" and .event.type == "feed")] | length > 0' \
        "$tape_output" >/dev/null; then
        break
    fi
    sleep 1
done
jq -e -s --argjson v "$tape_version" '(.[0] | .kind == "start" and .version == $v and .capture == "dump"
             and .format == "replay" and .reconstructible == false)
    and (last | .kind == "end" and .reason == "dump-complete")
    and ([.[] | select(.kind == "event" and .event.type == "feed")] | length > 0)' \
    "$tape_output" >/dev/null
slot_cli pane tape --pane "$pane_id" --format inspect >"$inspect_output"
jq -e -s --argjson v "$tape_version" '(.[0] | .kind == "start" and .version == $v and .format == "inspect")
    and ([.[] | select(.kind == "event" and (.event.spans | type) == "array")] | length > 0)
    and ([.[] | select(.event.base64 != null)] | length == 0)' \
    "$inspect_output" >/dev/null
slot_cli pane snapshot --pane "$pane_id" >"$snapshot_output"
jq -e -s --argjson v "$tape_version" '(.[0] | .kind == "start" and .version == $v and .capture == "snapshot"
             and .reconstructible == true and .cursor == null)
    and ([.[] | select(.kind == "sync")] | length > 0)
    and (last | .kind == "end" and .reason == "snapshot-complete")' \
    "$snapshot_output" >/dev/null
python3 "$SCRIPT_DIR/scripts/terminal-tape-to-fixture.py" "$tape_output" "$tape_fixture" \
    --keep-identifiers --test TerminalCliSmokeTests >/dev/null
jq -e '.version == 1 and .provenance.source == "danterm" and (.events | length) > 0' \
    "$tape_fixture" >/dev/null
slot_cli focus | jq -e --arg pane "$pane_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null

info="$(slot_cli pane info --pane "$pane_id")"
printf '%s\n' "$info" | jq -e \
    --arg pane "$pane_id" \
    --arg tab "$tab_id" \
    --arg group "$group_id" \
    '.pane.id == $pane and .tab.id == $tab and .group.id == $group' >/dev/null

slot_cli group rename --group "$group_id" smoke group
slot_cli ls | jq -e \
    --arg group "$group_id" \
    '.groups[] | select(.id == $group and .name == "smoke group")' >/dev/null

run_cli --socket "$socket" group rename --group "$group_id" '   '
[[ $status -ne 0 ]]
grep -qx 'danterm: invalid name' "$err"
slot_cli ls | jq -e \
    --arg group "$group_id" \
    '.groups[] | select(.id == $group and .name == "smoke group")' >/dev/null

new_group="$(slot_cli group new --name smoke-group --title smoke-group-tab)"
new_group_id="$(printf '%s\n' "$new_group" | jq -er '.group.id')"
new_group_tab_id="$(printf '%s\n' "$new_group" | jq -er '.tab.id')"
slot_cli ls | jq -e \
    --arg group "$new_group_id" \
    --arg tab "$new_group_tab_id" \
    '.groups[] | select(.id == $group and .name == "smoke-group")
        | ([.tabs[].id] == [$tab])' >/dev/null
slot_cli ls | jq -e --arg tab "$tab_id" '.selectedTabId == $tab' >/dev/null

slot_cli group close --group "$new_group_id"
slot_cli ls | jq -e --arg group "$new_group_id" \
    '[.groups[] | select(.id == $group)] | length == 0' >/dev/null
slot_cli ls | jq -e --arg tab "$new_group_tab_id" \
    '[.groups[].tabs[] | select(.id == $tab)] | length == 0' >/dev/null

run_cli --socket "$socket" group close --group "$group_id"
[[ $status -ne 0 ]]
grep -qx 'danterm: cannot close the last group' "$err"
slot_cli ls | jq -e --arg group "$group_id" \
    '[.groups[] | select(.id == $group)] | length == 1' >/dev/null

slot_cli tab rename --tab "$tab_id" test123
slot_cli ls | jq -e \
    --arg tab "$tab_id" \
    '.groups[].tabs[] | select(.id == $tab and .customTitle == "test123")' >/dev/null

other_pane_id="$(slot_cli tab new --group "$group_id" --title smoke-tab | jq -er '.panes[0].id')"
focused_split_id="$(slot_cli pane split --pane "$pane_id" -h --foreground --title focus-foreground | jq -er '.pane.id')"
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane zoom --pane "$focused_split_id" on | jq -e '.tab.isZoomed == true' >/dev/null
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane zoom --pane "$focused_split_id" off | jq -e '.tab.isZoomed == false' >/dev/null
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
background_split_id="$(slot_cli pane split --pane "$other_pane_id" -v --foreground --title focus-background | jq -er '.pane.id')"
slot_cli focus | jq -e --arg pane "$focused_split_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli pane close --pane "$background_split_id"
slot_cli pane close --pane "$focused_split_id"
slot_cli focus | jq -e --arg pane "$pane_id" \
    '. == {"focus": {"type": "terminal", "paneId": $pane}}' >/dev/null
slot_cli tab new --group "$group_id" --at-group-end --title smoke-tab-end | jq -e '.tab.id and .panes[0].id' >/dev/null
close_id="$(slot_cli tab new --group "$group_id" --title close-test | jq -r '.tab.id')"
slot_cli tab close --tab "$close_id"
slot_cli ls | jq -e --arg t "$close_id" '[.groups[].tabs[] | select(.id == $t)] | length == 0' >/dev/null
split_pane_id="$(slot_cli pane split --pane "$pane_id" -h --title smoke-split | jq -r '.pane.id')"
[[ -n "$split_pane_id" && "$split_pane_id" != "null" ]]

run_cli --socket "$socket" pane close --pane "$split_pane_id"
[[ $status -eq 0 ]]
[[ ! -s "$out" ]]
[[ ! -s "$err" ]]
slot_cli ls | jq -e \
    --arg pane "$split_pane_id" \
    --arg tab "$tab_id" \
    '([.. | objects | select(.id? == $pane)] | length == 0) and ([.groups[].tabs[] | select(.id == $tab)] | length == 1)' >/dev/null

run_cli --socket "$socket" pane close
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: usage: danterm pane close --pane <pane-id>' "$err"

slot_cli pane focus --pane "$other_pane_id"
slot_cli theme set --pane "$pane_id" SmokeTheme
slot_cli ls | jq -e \
    --arg target "$pane_id" \
    --arg focused "$other_pane_id" \
    '([.. | objects | select(.id? == $target and .theme? == "SmokeTheme")] | length == 1)
     and ([.. | objects | select(.id? == $focused and .theme? == null)] | length == 1)' >/dev/null
run_cli --socket "$socket" theme set SmokeTheme
[[ $status -ne 0 ]]
[[ ! -s "$out" ]]
grep -qx 'danterm: usage: danterm theme set --pane <pane-id> <name>|--clear' "$err"
slot_cli ls | jq -e \
    --arg target "$pane_id" \
    --arg focused "$other_pane_id" \
    '([.. | objects | select(.id? == $target and .theme? == "SmokeTheme")] | length == 1)
     and ([.. | objects | select(.id? == $focused and .theme? == null)] | length == 1)' >/dev/null
slot_cli theme set --pane "$pane_id" --clear

todo_id="$(slot_cli todo add --pane "$pane_id" 'ship cli' | jq -r '.todo.id')"
slot_cli todo list --pane "$pane_id" | jq -e --arg id "$todo_id" '.todos[] | select(.id == $id)' >/dev/null
slot_cli todo edit --pane "$pane_id" "$todo_id" 'ship cli v2'
slot_cli todo "done" --pane "$pane_id" "$todo_id"
slot_cli todo delete --pane "$pane_id" "$todo_id"

/usr/bin/python3 - "$socket" <<'PY'
import json
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(5)
    sock.connect(sys.argv[1])
    stream = sock.makefile("rwb")
    stream.readline()
    stream.write(b'{"jsonrpc":"2.0","id":1,"method":"unknown"}\n')
    stream.flush()
    for raw in stream:
        response = json.loads(raw)
        if response.get("id") == 1:
            code = response.get("error", {}).get("code")
            if code != -32601:
                raise SystemExit(f"expected -32601, got {code!r}")
            break
    else:
        raise SystemExit("no response for unknown method")
PY

release_slot
# `--stop` waits for the slot lock to release, but the socket file can outlive the
# app that bound it. Written as an `if` because a bare `[[ ... ]] && break` whose test
# fails on the final pass is the loop body's last command, and errexit would end the
# run there rather than fall through to the assertion below.
for _ in $(seq 1 10); do
    if [[ ! -S "$socket" ]]; then
        break
    fi
    sleep 0.5
done
if env -u DANTERM_PANE "$CLI_PATH" --socket "$socket" ls >"$smoke_output" 2>"$smoke_error"; then
    echo "danterm ls unexpectedly succeeded after app quit" >&2
    exit 1
fi
grep -qx 'danterm: DanTerm is not running' "$smoke_error"
