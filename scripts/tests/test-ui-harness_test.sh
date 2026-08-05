#!/usr/bin/env bash
# Contract test for checkout-independent UI harness build artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "test-ui-harness_test: $*" >&2
    exit 1
}

FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/checkout-a" "$TEST_ROOT/checkout-b"
cp "$REPO_ROOT/test-ui.sh" "$TEST_ROOT/checkout-a/test-ui.sh"
cp "$REPO_ROOT/test-ui.sh" "$TEST_ROOT/checkout-b/test-ui.sh"

export UI_COMPILE_LOG="$TEST_ROOT/compile.log"
export UI_RUN_LOG="$TEST_ROOT/run.log"
cat > "$FAKE_BIN/xcrun" <<'SHIM'
#!/usr/bin/env bash
output=""
ui_build=0
while (( $# > 0 )); do
    case "$1" in
        -D)
            [[ "${2:-}" == "DANTERM_UI_TEST" ]] && ui_build=1
            shift 2
            ;;
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "$output" ]] || exit 0
mkdir -p "$(dirname "$output")"
if (( ui_build )); then
    printf '%s\n' "$output" >> "$UI_COMPILE_LOG"
    cat > "$output" <<'RUNNER'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$UI_RUN_LOG"
RUNNER
    chmod +x "$output"
else
    : > "$output"
fi
SHIM
chmod +x "$FAKE_BIN/xcrun"

# Intent: concurrent UI harnesses compile and execute different binaries.
# Why it exists: a fixed /tmp output lets one checkout replace another checkout's
#   binary after compilation but before execution.
# Scenario: two agents run `just test-ui` concurrently from separate worktrees.
PATH="$FAKE_BIN:/usr/bin:/bin" "$TEST_ROOT/checkout-a/test-ui.sh" \
    > "$TEST_ROOT/a.out" 2> "$TEST_ROOT/a.err" &
pid_a=$!
PATH="$FAKE_BIN:/usr/bin:/bin" "$TEST_ROOT/checkout-b/test-ui.sh" \
    > "$TEST_ROOT/b.out" 2> "$TEST_ROOT/b.err" &
pid_b=$!

status_a=0
status_b=0
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
[[ $status_a -eq 0 ]] || fail "checkout A exited $status_a: $(cat "$TEST_ROOT/a.err")"
[[ $status_b -eq 0 ]] || fail "checkout B exited $status_b: $(cat "$TEST_ROOT/b.err")"

compile_paths=()
while IFS= read -r path; do
    compile_paths+=("$path")
done < "$UI_COMPILE_LOG"
run_paths=()
while IFS= read -r path; do
    run_paths+=("$path")
done < "$UI_RUN_LOG"
[[ ${#compile_paths[@]} -eq 2 ]] || fail "expected two UI compile paths"
[[ ${#run_paths[@]} -eq 2 ]] || fail "expected two UI run paths"
[[ "${compile_paths[0]}" != "${compile_paths[1]}" ]] \
    || fail "concurrent checkouts shared UI binary ${compile_paths[0]}"

for path in "${compile_paths[@]}"; do
    printf '%s\n' "${run_paths[@]}" | grep -qFx "$path" \
        || fail "compiled UI binary was not the one executed: $path"
done

echo "test-ui-harness_test: ok"
