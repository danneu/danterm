#!/usr/bin/env bash
# Contract test for the UI harness compiler invocation and checkout-independent artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/bounded-wait.sh
source "$REPO_ROOT/scripts/lib/bounded-wait.sh"

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
export UI_SOURCE_LOG="$TEST_ROOT/source.log"
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
        *.swift)
            printf '%s\n' "$1" >> "$UI_SOURCE_LOG"
            shift
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
# These two take a lock against each other, and a deadlock in that lock is exactly
# what this test exists to catch. Without the watchdog the deadlock would park the
# waits below instead of failing them, and report nothing at all.
watchdog="$(start_watchdog 300 "$pid_a" "$pid_b")"
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
cancel_watchdog "$watchdog"
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

# Intent: the UI compiler receives the portable pane-tape values used by TerminalSession.
# Why it exists: the explicit harness source list can omit a dependency that the app target
#   receives automatically.
# Scenario: each concurrent checkout compiles the complete TerminalSession source boundary.
pane_tape_source_count="$(grep -c '/PaneTapeRecords.swift$' "$UI_SOURCE_LOG" || true)"
[[ "$pane_tape_source_count" -eq 2 ]] \
    || fail "expected PaneTapeRecords.swift in both UI compiler invocations"

# Intent: every production source the harness is able to compile stays in the compiler
#   invocation, and `tests-ui/` re-declares none of the names those sources supply.
# Why it exists: the harness used to fake these declarations, and the copies drifted from
#   production while every UI test stayed green. Both halves are needed -- dropping a source
#   and restoring its fake removes the very name a collision check would compare against.
# Scenario: someone deletes a source from the list, or adds a convenient local copy of a
#   production type back into `tests-ui/`.
HARNESS_COMPILED_SOURCES=(
    "lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift"
    "lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift"
    "lib/TerminalPTY/Sources/TerminalPaneSession/TerminalGridSizing.swift"
    "lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift"
    "lib/TerminalCore/Sources/TerminalCore/TerminalSemanticEvent.swift"
    "lib/TerminalCore/Sources/TerminalCore/TerminalSearchStatus.swift"
)

for source in "${HARNESS_COMPILED_SOURCES[@]}"; do
    count="$(grep -c "/${source}\$" "$UI_SOURCE_LOG" || true)"
    [[ "$count" -eq 2 ]] \
        || fail "expected $source in both UI harness builds, saw it $count time(s)"
done

# Only column-0 declarations count: a nested type inside a fake legitimately reuses a name.
declaration_names() {
    grep -hoE '^(public )?(final )?(struct|enum|class|actor|protocol|func) [A-Za-z_][A-Za-z0-9_]*' "$@" \
        | awk '{ print $NF }' | sort -u
}

absolute_sources=()
for source in "${HARNESS_COMPILED_SOURCES[@]}"; do
    absolute_sources+=("$REPO_ROOT/$source")
done
shadowed="$(comm -12 \
    <(declaration_names "${absolute_sources[@]}") \
    <(declaration_names "$REPO_ROOT"/tests-ui/*.swift))"
[[ -z "$shadowed" ]] \
    || fail "tests-ui re-declares harness-compiled production names: $(tr '\n' ' ' <<< "$shadowed")"

for path in "${compile_paths[@]}"; do
    printf '%s\n' "${run_paths[@]}" | grep -qFx "$path" \
        || fail "compiled UI binary was not the one executed: $path"
done

echo "test-ui-harness_test: ok"
