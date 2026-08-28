#!/usr/bin/env bash
# Pins both directions of scripts/kitten-benchmark-parity-lint.py.
#
# The lint exists to notice two different failures, and a self-test that only proved the
# happy path would leave either one free to appear. So every case below either mutates the
# pinned kitty sources and demands a failure, or leaves them alone and demands a pass:
#
#   - the reference moving under a port that did not follow it (a constant edited in
#     main.go, a mode number or a saved-state string edited in terminal-state.go);
#   - the port's recorded reference hashes going stale or disappearing, which is the half
#     that catches a pin bump touching something the parser does not read.
#
# The baseline tree is the real checkout copied aside, and the port's parameters come from
# the real `TerminalCoreBenchmark describe`, so a pass here means the shipped port really
# does match the pinned reference -- not that two fixtures agree with each other.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINT="$SCRIPT_DIR/../kitten-benchmark-parity-lint.py"
PORT="lib/TerminalCore/Sources/KittenFeedFixture/KittenFeedFixture.swift"
REFERENCE="$ROOT/references/kitty"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

if [ ! -f "$REFERENCE/tools/cmd/benchmark/main.go" ] \
    || [ ! -f "$REFERENCE/tools/tui/loop/terminal-state.go" ]; then
    # Same contract as the lint: no checkout is no evidence, so report and pass. The
    # absence case itself is still asserted below against a tree with no references.
    echo "kitten-benchmark-parity lint self-test skipped: no kitty checkout at $REFERENCE"
    echo "(run \`just fetch-references kitty\`)"
    exit 0
fi

PARAMETERS="$TMP/parameters.json"
swift run --package-path "$ROOT/lib/TerminalCore" TerminalCoreBenchmark describe \
    > "$PARAMETERS" 2>/dev/null \
    || fail "could not ask TerminalCoreBenchmark for its parameters"

passes() { python3 "$LINT" "$1" --parameters "$PARAMETERS" >/dev/null 2>&1; }
expect_pass() { passes "$1" || fail "$2"; }
expect_fail() { ! passes "$1" || fail "$2"; }

# Fails and names the given invariant in its stderr, so a case cannot pass by tripping a
# different rule than the one it is about.
expect_fail_with() {
    local case_root="$1" invariant="$2" message="$3"
    if python3 "$LINT" "$case_root" --parameters "$PARAMETERS" >/dev/null 2>"$TMP/stderr"; then
        fail "$message"
    fi
    grep -q "\[$invariant\]" "$TMP/stderr" || fail "$message (no $invariant in the report)"
}

edit_file() {
    local target="$1" script="$2"
    sed -E "$script" "$target" > "$target.new" && mv "$target.new" "$target"
}

BASE="$TMP/valid"
mkdir -p "$BASE/references/kitty/tools/cmd/benchmark" \
    "$BASE/references/kitty/tools/tui/loop" \
    "$BASE/$(dirname "$PORT")"
cp "$REFERENCE/tools/cmd/benchmark/main.go" "$BASE/references/kitty/tools/cmd/benchmark/"
cp "$REFERENCE/tools/tui/loop/terminal-state.go" "$BASE/references/kitty/tools/tui/loop/"
cp "$ROOT/$PORT" "$BASE/$PORT"

BENCHMARK="references/kitty/tools/cmd/benchmark/main.go"
LOOP="references/kitty/tools/tui/loop/terminal-state.go"

new_case() {
    local name="$1"
    rm -rf "${TMP:?}/$name"
    cp -R "$BASE" "$TMP/$name"
    echo "$TMP/$name"
}

expect_pass "$BASE" "the shipped port must match the pinned kitty sources"

CASE="$(new_case alphabet)"
edit_file "$CASE/$BENCHMARK" 's/^const ascii_printable = "abc/const ascii_printable = "zbc/'
expect_fail_with "$CASE" I1 "an edited ascii alphabet must fail"

CASE="$(new_case size)"
edit_file "$CASE/$BENCHMARK" 's/const sz = 1024\*1024 \+ 17/const sz = 1024*1024 + 18/'
expect_fail_with "$CASE" I1 "an edited csi payload size must fail"

CASE="$(new_case band)"
edit_file "$CASE/$BENCHMARK" 's/case \(30 <= q \&\& q < 40\):/case (30 <= q \&\& q < 41):/'
expect_fail_with "$CASE" I1 "an edited csi probability band must fail"

CASE="$(new_case description)"
edit_file "$CASE/$BENCHMARK" 's/const desc = "Only ASCII chars"/const desc = "Only ASCII bytes"/'
expect_fail_with "$CASE" I1 "an edited arm description must fail"

CASE="$(new_case saved_state)"
edit_file "$CASE/$LOOP" 's/SAVE_PRIVATE_MODE_VALUES      = "\\033\[\?s"/SAVE_PRIVATE_MODE_VALUES      = "\\033[?t"/'
expect_fail_with "$CASE" I2 "an edited saved-state escape code must fail"

CASE="$(new_case mode_number)"
edit_file "$CASE/$LOOP" 's/ALTERNATE_SCREEN                 Mode = 1049 \| private/ALTERNATE_SCREEN                 Mode = 1047 | private/'
expect_fail_with "$CASE" I2 "an edited mode number must fail"

CASE="$(new_case mode_list)"
edit_file "$CASE/$LOOP" 's/set_modes\(&sb, DECARM, DECAWM, DECTCEM\)/set_modes(\&sb, DECARM, DECTCEM)/'
expect_fail_with "$CASE" I2 "a mode dropped from the set list must fail"

CASE="$(new_case keyboard_flags)"
edit_file "$CASE/$LOOP" 's/sb\.WriteString\("\\033\[>u"\)/sb.WriteString("\\033[>1u")/'
expect_fail_with "$CASE" I2 "an edited keyboard-flag literal must fail"

CASE="$(new_case stale_hash)"
edit_file "$CASE/$PORT" 's/body sha256:[0-9a-f]{12}\)/body sha256:000000000000)/'
expect_fail_with "$CASE" I3 "a stale recorded reference hash must fail"

CASE="$(new_case missing_citation)"
edit_file "$CASE/$PORT" '/Adapted from tools\/tui\/loop/d'
expect_fail_with "$CASE" I3 "a missing reference citation must fail"

CASE="$(new_case absent_reference)"
rm -rf "$CASE/references"
OUTPUT="$(python3 "$LINT" "$CASE" --parameters "$PARAMETERS" 2>&1)" \
    || fail "an absent kitty checkout must exit 0"
echo "$OUTPUT" | grep -q "skipped" \
    || fail "an absent kitty checkout must say it was skipped"

echo "kitten-benchmark-parity lint self-test passed"
