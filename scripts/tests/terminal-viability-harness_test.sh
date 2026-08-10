#!/usr/bin/env bash
# Behavioral tests for the terminal viability harness's safety and evidence helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$SCRIPT_DIR/terminal-viability.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "terminal-viability-harness_test: $*" >&2
    exit 1
}

fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/swift" <<EOF
#!/usr/bin/env bash
touch "$TEST_ROOT/swift-ran"
exit 99
EOF
chmod +x "$fake_bin/swift"

# Intent: every safety refusal happens before a build or app-control command.
# Why it exists: the viability gate may synthesize input and terminate only the
#   isolated app it launched, so accidental invocation must be inert.
# Scenario: a developer omits the opt-in, has a non-zsh account shell, or uses
#   a non-U.S. input source and invokes the recipe from a normal shell.
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$HARNESS" \
    >"$TEST_ROOT/no-opt-in.out" 2>"$TEST_ROOT/no-opt-in.err"; then
    fail "script succeeded without app-control opt-in"
else
    status=$?
fi
[[ $status -eq 2 ]] || fail "missing opt-in exited $status instead of 2"
[[ ! -e "$TEST_ROOT/swift-ran" ]] || fail "build ran before the opt-in refusal"

cat >"$fake_bin/dscacheutil" <<'EOF'
#!/usr/bin/env bash
printf 'name: test\nshell: /bin/bash\n'
EOF
cat >"$fake_bin/defaults" <<'EOF'
#!/usr/bin/env bash
printf 'com.apple.keylayout.US\n'
EOF
chmod +x "$fake_bin/dscacheutil" "$fake_bin/defaults"
if DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$HARNESS" \
    >"$TEST_ROOT/non-zsh.out" 2>"$TEST_ROOT/non-zsh.err"; then
    fail "script accepted a non-zsh account shell"
fi
[[ ! -e "$TEST_ROOT/swift-ran" ]] || fail "build ran before the shell refusal"
grep -qF 'zsh account shell' "$TEST_ROOT/non-zsh.err" \
    || fail "shell refusal omitted its prerequisite"

cat >"$fake_bin/dscacheutil" <<'EOF'
#!/usr/bin/env bash
printf 'name: test\nshell: /bin/zsh\n'
EOF
cat >"$fake_bin/defaults" <<'EOF'
#!/usr/bin/env bash
printf 'com.apple.keylayout.French\n'
EOF
chmod +x "$fake_bin/dscacheutil" "$fake_bin/defaults"
if DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$HARNESS" \
    >"$TEST_ROOT/non-us.out" 2>"$TEST_ROOT/non-us.err"; then
    fail "script accepted a non-U.S. input source"
fi
[[ ! -e "$TEST_ROOT/swift-ran" ]] || fail "build ran before the input-source refusal"
grep -qF 'U.S./ABC input source' "$TEST_ROOT/non-us.err" \
    || fail "input-source refusal omitted its prerequisite"

cat >"$fake_bin/defaults" <<'EOF'
#!/usr/bin/env bash
printf 'com.apple.keylayout.US\n'
EOF
cat >"$fake_bin/osascript" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *kCGEventSourceStateHIDSystemState*) printf '65536\n' ;;
    *) printf '0\n' ;;
esac
EOF
chmod +x "$fake_bin/defaults" "$fake_bin/osascript"
rm -f "$TEST_ROOT/swift-ran"
if DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$HARNESS" \
    >"$TEST_ROOT/caps-lock.out" 2>"$TEST_ROOT/caps-lock.err"; then
    fail "script accepted Caps Lock before lowercase keyboard evidence"
fi
[[ ! -e "$TEST_ROOT/swift-ran" ]] || fail "build ran before the Caps Lock refusal"
grep -qF 'Caps Lock must be off' "$TEST_ROOT/caps-lock.err" \
    || fail "Caps Lock refusal omitted its prerequisite"

# The path is resolved from SCRIPT_DIR at runtime.
# shellcheck disable=SC1090,SC1091
source "$HARNESS"

archive_root="$TEST_ROOT/preserved-run"
mkdir -p "$archive_root"
runtime_root="$(make_short_runtime_alias "$archive_root")"
[[ -L "$runtime_root" ]] || fail "runtime root is not a symlink"
[[ "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$runtime_root")" == \
    "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$archive_root")" ]] \
    || fail "runtime root does not resolve to the preserved run"
socket_path="$runtime_root/home/Library/Caches/com.danneu.danterm-terminal-viability/control.sock"
assert_unix_socket_path_fits "$socket_path" \
    || fail "short runtime root still exceeds the Unix socket path budget"
long_socket_path="$TEST_ROOT/$(printf 'x%.0s' $(seq 1 104))"
if assert_unix_socket_path_fits "$long_socket_path"; then
    fail "overlong Unix socket path was accepted"
fi
unlink "$runtime_root"

markers="$TEST_ROOT/markers.txt"
cat >"$markers" <<'EOF'
noise
REGION-BEGIN
long logical line
hard break
REGION-END
tail
EOF
extract_marker_region "$markers" REGION-BEGIN REGION-END "$TEST_ROOT/region.txt" \
    || fail "valid marker region was rejected"
cat >"$TEST_ROOT/expected-region.txt" <<'EOF'
REGION-BEGIN
long logical line
hard break
REGION-END
EOF
cmp -s "$TEST_ROOT/expected-region.txt" "$TEST_ROOT/region.txt" \
    || fail "marker extraction changed the bounded region"

printf 'REGION-BEGIN\nno end\n' >"$TEST_ROOT/missing-end.txt"
if extract_marker_region "$TEST_ROOT/missing-end.txt" REGION-BEGIN REGION-END \
    "$TEST_ROOT/missing-output.txt"; then
    fail "marker extraction accepted a missing end marker"
fi

pane_id="11111111-2222-3333-4444-555555555555"
cat >"$TEST_ROOT/good-events.log" <<EOF
session.visibilityChanged:$pane_id:false
session.visibilityChanged:$pane_id:true
session.planDelivered
EOF
assert_hidden_trace "$TEST_ROOT/good-events.log" "$pane_id" \
    || fail "event-ordered hidden/reveal evidence was rejected"

cat >"$TEST_ROOT/bad-events.log" <<EOF
session.visibilityChanged:$pane_id:false
session.planDelivered
session.visibilityChanged:$pane_id:true
session.planDelivered
EOF
if assert_hidden_trace "$TEST_ROOT/bad-events.log" "$pane_id"; then
    fail "hidden-pane plan delivery was accepted"
fi

echo "terminal viability harness tests passed"
