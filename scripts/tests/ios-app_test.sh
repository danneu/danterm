#!/usr/bin/env bash
# Contract tests for the iOS app runner: `scripts/ios-app.sh`'s command surface, and
# the bundle payload `scripts/assemble-ios-app.sh` produces for it.
#
# Compiling is not this file's job. `scripts/ios-portability-gate.sh` cross-compiles
# `ios/DanTermMobileApp` for the device triple, so a source break fails there. What
# nothing else watches is the assembly: the payload names one repository path per
# file, and a theme or font that moves still yields a signed, installable .app -- one
# with no theme in it. That break reaches a human as a dead screen on the phone, a
# build and an install later, so it is pinned here.
#
# The fixture copies those resources from the real tree rather than inventing them,
# which is what makes a rename fail: the copy is the existence assertion.
#
# Apple tooling is shimmed, not run. `swift` and `xcrun` are stubs on PATH, so the
# real runner walks its whole simulator path over a fixture repository in
# milliseconds -- and that is also what proves the runner delegates to the assembler,
# which reading the assembler alone can never show.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SYMBOLS_REL="lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
THEME_REL="themes/Builtin Dark.json"
PLIST_REL="ios/DanTermMobileApp/Info.plist"

fail() {
    echo "ios-app_test: $*" >&2
    exit 1
}

# Copying from the real tree is deliberate: it is the assertion that the path the
# assembler hard-codes still names a file. A fixture written from scratch would keep
# passing after the resource it stands for was renamed.
copy_source() {
    local relative="$1" destination="$2"
    [[ -f "$ROOT_DIR/$relative" ]] \
        || fail "the repository has no '$relative', but scripts/assemble-ios-app.sh copies it into every iOS bundle"
    cp "$ROOT_DIR/$relative" "$destination"
}

build_fixture() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/$(dirname "$PLIST_REL")" "$root/$SYMBOLS_REL" "$root/themes" \
        "$root/icon/AppIcon.icon/Assets"
    cp "$ROOT_DIR/scripts/ios-app.sh" "$root/scripts/"
    cp "$ROOT_DIR/scripts/assemble-ios-app.sh" "$root/scripts/"
    cat > "$root/scripts/dev-slot-launcher.py" <<'SHIM'
#!/usr/bin/env python3
# Stands in for the slot pool's `--list` survey, which `--slot` reads its endpoint from.
import os
print(os.environ.get("SHIM_SLOTS_JSON", "[]"))
SHIM
    chmod +x "$root/scripts/dev-slot-launcher.py"
    copy_source "$PLIST_REL" "$root/$PLIST_REL"
    copy_source "$SYMBOLS_REL/SymbolsNerdFontMono-Regular.ttf" "$root/$SYMBOLS_REL/"
    copy_source "$SYMBOLS_REL/LICENSE" "$root/$SYMBOLS_REL/"
    copy_source "$THEME_REL" "$root/$THEME_REL"
    copy_source "icon/AppIcon.icon/icon.json" "$root/icon/AppIcon.icon/icon.json"
    copy_source "icon/AppIcon.icon/Assets/raw.svg" "$root/icon/AppIcon.icon/Assets/raw.svg"
}

# Intent: an unrecognized target is rejected with the documented usage line.
# Why it exists: the runner's first argument selects between a simulator install and
#   a signed device install, so a typo must stop rather than pick a default.
# Scenario: someone runs `ios-app.sh sim` from memory.
set +e
OUTPUT="$("$ROOT_DIR/scripts/ios-app.sh" invalid 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail "ios-app.sh accepted an invalid target"
[[ "$OUTPUT" == "usage: ios-app.sh [simulator|device] [--slot <n>] [target-id]" ]] \
    || fail "unexpected usage output: $OUTPUT"

FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/swift" <<'SHIM'
#!/usr/bin/env bash
# Stands in for `swift build`, writing the product where SwiftPM would leave it.
set -eu
build_path=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--build-path" ]]; then
        build_path="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "$build_path" ]] || { echo "shim swift: no --build-path" >&2; exit 1; }
bin="$build_path/arm64-apple-ios-simulator/debug"
mkdir -p "$bin"
printf 'fixture-binary\n' > "$bin/DanTermMobileApp"
chmod +x "$bin/DanTermMobileApp"
SHIM
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/xcrun" <<'SHIM'
#!/usr/bin/env bash
# Answers the two queries the simulator path reads; every other simctl verb is a no-op.
set -eu
case "$*" in
    actool\ *)
        compile=""
        partial=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --compile) compile="$2"; shift 2 ;;
                --output-partial-info-plist) partial="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$compile" && -n "$partial" ]] \
            || { echo "shim xcrun: incomplete actool arguments" >&2; exit 1; }
        mkdir -p "$compile"
        printf 'fixture-assets\n' > "$compile/Assets.car"
        printf 'fixture-phone-icon\n' > "$compile/AppIcon60x60@2x.png"
        /usr/bin/python3 - "$partial" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as stream:
    plistlib.dump({
        "CFBundleIcons": {
            "CFBundlePrimaryIcon": {
                "CFBundleIconFiles": ["AppIcon60x60"],
                "CFBundleIconName": "AppIcon",
            },
        },
    }, stream)
PY
        ;;
    *--show-sdk-path*)
        echo "/fixture/sdk"
        ;;
    "simctl list devices available --json")
        echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"udid":"FIXTURE-UDID"}]}}'
        ;;
    simctl\ launch\ *)
        # Records the environment the client was launched with, which is the only
        # observable end of the `--slot` wiring. `unset` and an empty value are
        # distinguished deliberately: the app reads an absent variable as "no launch
        # target" and falls back to the target the user saved.
        if [[ -n "${SHIM_LAUNCH_LOG:-}" ]]; then
            printf '%s %s %s\n' \
                "${SIMCTL_CHILD_DANTERM_IOS_HOST-unset}" \
                "${SIMCTL_CHILD_DANTERM_IOS_PORT-unset}" \
                "${SIMCTL_CHILD_DANTERM_IOS_SMOKE_INPUT-unset}" > "$SHIM_LAUNCH_LOG"
        fi
        ;;
esac
SHIM
chmod +x "$FAKE_BIN/xcrun"

# Intent: a simulator run assembles a bundle carrying the product and every runtime
#   resource, with the repository's bytes.
# Why it exists: each resource is copied from a path written into the assembler. A
#   renamed theme or a moved symbol font produces a bundle that installs and launches
#   into nothing, and no compile or lint sees it.
# Scenario: `ios-app.sh simulator` on a checkout, with Apple tooling shimmed away.
FIXTURE="$TEST_ROOT/repo"
build_fixture "$FIXTURE"
if ! PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$FIXTURE/scripts/ios-app.sh" simulator > "$TEST_ROOT/run.out" 2>&1; then
    echo "--- runner output ---" >&2
    cat "$TEST_ROOT/run.out" >&2
    fail "the simulator run failed on a complete repository fixture"
fi

APP="$FIXTURE/.spm-build/ios-app/simulator/DanTerm.app"
[[ -x "$APP/DanTermMobileApp" ]] \
    || fail "the bundle has no executable DanTermMobileApp"
cmp -s "$ROOT_DIR/$PLIST_REL" "$APP/Info.plist" \
    && fail "the bundle's Info.plist has no compiled icon metadata"
[[ -f "$APP/Assets.car" ]] || fail "the bundle is missing the compiled icon catalog"
[[ -f "$APP/AppIcon60x60@2x.png" ]] || fail "the bundle is missing the phone icon rendition"
[[ "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw "$APP/Info.plist")" == "AppIcon" ]] \
    || fail "the bundle does not name AppIcon as its primary icon"
cmp "$ROOT_DIR/$SYMBOLS_REL/SymbolsNerdFontMono-Regular.ttf" \
    "$APP/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" \
    || fail "the bundle is missing the Nerd Fonts symbol font"
cmp "$ROOT_DIR/$SYMBOLS_REL/LICENSE" "$APP/NerdFontsSymbolsOnly/LICENSE" \
    || fail "the bundle is missing the symbol font license"
cmp "$ROOT_DIR/$THEME_REL" "$APP/Themes/$(basename "$THEME_REL")" \
    || fail "the bundle is missing the built-in theme"

# Intent: `--slot` on a slot that holds no tailnet listener stops and says how to get one.
# Why it exists: a slot's listen port comes from its own identity, so the 7420 default is
#   wrong for it. Launching anyway produces a client that silently never connects.
# Scenario: someone runs `just ios-app --slot 4` against a slot launched without --tailnet.
set +e
OUTPUT="$(SHIM_SLOTS_JSON='[{"slot":4}]' \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$FIXTURE/scripts/ios-app.sh" simulator --slot 4 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail "ios-app.sh launched against a slot with no tailnet listener"
grep -qF -- "--tailnet" <<<"$OUTPUT" \
    || fail "the runner did not say how to get a listener: $OUTPUT"

# Intent: `--slot` launches the client against that slot's own endpoint.
# Why it exists: this is the whole point of the flag -- reading the endpoint back off the
#   slot instead of the caller copying it out of a launch handle by hand.
# Scenario: `just ios-app --slot 4` after `just launch-slot --tailnet` reported :7422.
LAUNCH_LOG="$TEST_ROOT/launch.env"
SHIM_SLOTS_JSON='[{"slot":4,"tailnet":{"state":"listening","endpoint":"100.64.0.7:7422"}}]' \
    SHIM_LAUNCH_LOG="$LAUNCH_LOG" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$FIXTURE/scripts/ios-app.sh" simulator --slot 4 > "$TEST_ROOT/slot.out" 2>&1 \
    || { cat "$TEST_ROOT/slot.out" >&2; fail "the --slot run failed"; }
[[ "$(cat "$LAUNCH_LOG")" == "100.64.0.7 7422 unset" ]] \
    || fail "the client was not aimed at the slot's endpoint: $(cat "$LAUNCH_LOG")"

# Intent: an ordinary run names no launch target, even when the invoking shell exports
#   one.
# Why it exists: a launch target overrides the server the user saved in the app, and the
#   runner used to install one on every run -- an inherited host, or port 7420 against a
#   saved host that listens elsewhere. `--slot` is the only way to name a target now, so
#   an ordinary run must leave both variables absent rather than empty.
# Scenario: someone runs `just ios-app` in a shell where an earlier slot session left
#   DANTERM_IOS_HOST and DANTERM_IOS_PORT exported.
SHIM_LAUNCH_LOG="$LAUNCH_LOG" \
    DANTERM_IOS_HOST="stale.tailnet" \
    DANTERM_IOS_PORT="7433" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$FIXTURE/scripts/ios-app.sh" simulator > "$TEST_ROOT/plain.out" 2>&1 \
    || { cat "$TEST_ROOT/plain.out" >&2; fail "the ordinary run failed"; }
[[ "$(cat "$LAUNCH_LOG")" == "unset unset unset" ]] \
    || fail "an ordinary run named a launch target: $(cat "$LAUNCH_LOG")"

# Intent: smoke input reaches the client on a run that names no target.
# Why it exists: the simulator probe drives its input through this variable while the
#   phone connects to whatever the user saved. Tying smoke input to target injection
#   would have made the probe unusable without also overriding the saved server.
# Scenario: the simulator smoke run, `DANTERM_IOS_SMOKE_INPUT='echo hi' just ios-app`.
SHIM_LAUNCH_LOG="$LAUNCH_LOG" \
    DANTERM_IOS_SMOKE_INPUT="echo hi" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$FIXTURE/scripts/ios-app.sh" simulator > "$TEST_ROOT/smoke.out" 2>&1 \
    || { cat "$TEST_ROOT/smoke.out" >&2; fail "the smoke run failed"; }
[[ "$(cat "$LAUNCH_LOG")" == "unset unset echo hi" ]] \
    || fail "smoke input did not reach the client: $(cat "$LAUNCH_LOG")"

# Intent: a resource that is gone stops the assembly and names the path.
# Why it exists: `cp` under `set -e` reports a failure, but the whole value here is
#   that the message says which file moved -- otherwise the next person re-derives it
#   from a bundle that is merely incomplete.
# Scenario: someone renames the built-in theme and rebuilds for the phone.
BROKEN="$TEST_ROOT/broken"
build_fixture "$BROKEN"
rm "$BROKEN/$THEME_REL"
mkdir -p "$TEST_ROOT/bin"
printf 'fixture-binary\n' > "$TEST_ROOT/bin/DanTermMobileApp"
set +e
OUTPUT="$("$BROKEN/scripts/assemble-ios-app.sh" \
    "$BROKEN" "$TEST_ROOT/bin" \
    "$FIXTURE/.spm-build/ios-app/simulator/app-icon" \
    "$FIXTURE/.spm-build/ios-app/simulator/app-icon-info.plist" \
    "$TEST_ROOT/broken.app" 2>&1)"
STATUS=$?
set -e
[[ "$STATUS" -ne 0 ]] || fail "the assembler produced a bundle with no theme"
grep -qF "$(basename "$THEME_REL")" <<<"$OUTPUT" \
    || fail "the assembler did not name the missing theme: $OUTPUT"

echo "ios-app tests passed"
