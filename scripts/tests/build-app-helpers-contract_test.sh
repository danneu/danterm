#!/usr/bin/env bash
# Contract tests for the release bundle's Helpers directory produced by build-app.sh.
#
# The GUI refuses to start a Swift terminal session without an executable
# Contents/Helpers/PTYSessionBootstrap, so a release bundle that omits it passes
# packaging checks and then dies at launch. These tests pin the helper's presence
# and its release-configuration provenance with a shimmed `swift`, so no real
# compile is needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "build-app-helpers-contract_test: $*" >&2
    exit 1
}

BUILD_ROOT="$TEST_ROOT/build-root"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$BUILD_ROOT/lib/TerminalPTY" \
    "$BUILD_ROOT/app" \
    "$BUILD_ROOT/icon/AppIcon" \
    "$BUILD_ROOT/integrations/claude-code" \
    "$BUILD_ROOT/integrations/codex" \
    "$BUILD_ROOT/integrations/shell-integration/vendor" \
    "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly" \
    "$BUILD_ROOT/scripts" \
    "$BUILD_ROOT/themes" \
    "$FAKE_BIN"
ln -s "$ROOT_DIR/build-app.sh" "$BUILD_ROOT/build-app.sh"
cp "$ROOT_DIR/scripts/bundle-theme-resources.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/themes/0x96f.json" "$BUILD_ROOT/themes/"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE"
cp "$ROOT_DIR/app/Info.plist" "$BUILD_ROOT/app/Info.plist"
: > "$BUILD_ROOT/icon/AppIcon/Assets.car"
: > "$BUILD_ROOT/integrations/claude-code/claude-notify-osc777.sh"
: > "$BUILD_ROOT/integrations/claude-code/danterm-agent-session.sh"
: > "$BUILD_ROOT/integrations/codex/danterm-agent-session.sh"
for shell in zsh bash fish; do
    printf '# fixture %s integration\n' "$shell" > "$BUILD_ROOT/integrations/shell-integration/danterm.$shell"
done
for vendored in bash-preexec.sh bash-preexec.LICENSE bash-preexec.PROVENANCE; do
    printf '# fixture %s\n' "$vendored" > "$BUILD_ROOT/integrations/shell-integration/vendor/$vendored"
done

# Each shimmed product gets distinct bytes: build-app.sh deliberately fails when
# the GUI and CLI binaries compare equal, and that guard must stay exercisable.
export SWIFT_ARGV_LOG="$TEST_ROOT/swift-argv.log"
: > "$SWIFT_ARGV_LOG"
cat > "$FAKE_BIN/swift" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWIFT_ARGV_LOG"
case " $* " in
    *" --show-bin-path "*)
        case " $* " in
            *"/TerminalPTY "*)
                bin_path="$TEST_ROOT/bootstrap-bin"
                mkdir -p "$bin_path"
                printf '#!/bin/sh\nexit 0\n' > "$bin_path/PTYSessionBootstrap"
                chmod +x "$bin_path/PTYSessionBootstrap"
                ;;
            *)
                bin_path="$TEST_ROOT/app-bin"
                mkdir -p "$bin_path"
                printf '#!/bin/sh\n# gui\nexit 0\n' > "$bin_path/DanTerm"
                printf '#!/bin/sh\n# cli\nexit 0\n' > "$bin_path/DanTermCLI"
                chmod +x "$bin_path/DanTerm" "$bin_path/DanTermCLI"
                ;;
        esac
        printf '%s\n' "$bin_path"
        ;;
esac
SHIM
chmod +x "$FAKE_BIN/swift"

set +e
TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/build-app.sh" --version 0.0.0-test \
    > "$TEST_ROOT/build.out" 2> "$TEST_ROOT/build.err"
status=$?
set -e
[[ $status -eq 0 ]] \
    || fail "build-app.sh failed (status $status): $(cat "$TEST_ROOT/build.err")"

APP_PATH="$BUILD_ROOT/build/DanTerm.app"

# Intent: the release bundle ships an executable PTY session bootstrap helper.
# Why it exists: the Swift terminal backend reports itself not ready without
#   Contents/Helpers/PTYSessionBootstrap, so a bundle missing it launches and
#   immediately fails instead of opening a session.
# Scenario: CI or the release workflow assembles a production bundle.
[[ -x "$APP_PATH/Contents/Helpers/PTYSessionBootstrap" ]] \
    || fail "release bundle omitted an executable Contents/Helpers/PTYSessionBootstrap"
cmp "$TEST_ROOT/bootstrap-bin/PTYSessionBootstrap" \
    "$APP_PATH/Contents/Helpers/PTYSessionBootstrap" \
    || fail "bundled PTYSessionBootstrap is not the built helper binary"

# Intent: the helper is compiled with the same release configuration as the app.
# Why it exists: reusing a debug build directory would ship an unoptimized helper
#   on the production path, silently diverging from the app it is bundled with.
# Scenario: build-app.sh is invoked as the canonical release build.
grep -q -- "--package-path $BUILD_ROOT/lib/TerminalPTY .* --product PTYSessionBootstrap" \
    "$SWIFT_ARGV_LOG" \
    || fail "build-app.sh did not build the PTYSessionBootstrap product"
[[ $(grep -c -- '--configuration release' "$SWIFT_ARGV_LOG") -eq $(wc -l < "$SWIFT_ARGV_LOG") ]] \
    || fail "not every SwiftPM invocation selected release configuration"

# Intent: the pre-existing CLI helper and GUI binary are still distinct artifacts.
# Why it exists: adding a third Helpers entry must not disturb the collision guard
#   that keeps a signed bundle from shipping the CLI bytes as the GUI.
# Scenario: the same release assembly run as above.
[[ -x "$APP_PATH/Contents/Helpers/danterm" ]] \
    || fail "release bundle omitted the danterm CLI helper"
if cmp -s "$APP_PATH/Contents/MacOS/DanTerm" "$APP_PATH/Contents/Helpers/danterm"; then
    fail "GUI and CLI bundle binaries have identical content"
fi

# Intent: the workflows that gate a release assert the helper is present.
# Why it exists: build-app.sh once produced a bundle whose default terminal
#   backend could not start, and every packaging check still passed.
# Scenario: reviewing CI and the stable-release workflow.
grep -q 'Contents/Helpers/PTYSessionBootstrap' "$ROOT_DIR/.github/workflows/ci.yml" \
    || fail "ci.yml bundle-layout check does not require PTYSessionBootstrap"
grep -q 'Contents/Helpers/PTYSessionBootstrap' "$ROOT_DIR/.github/workflows/release-stable.yml" \
    || fail "release-stable.yml layout check does not require PTYSessionBootstrap"

# Nested code must be signed before its container, or the outer signature seals a
# helper whose own signature is then replaced.
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release-stable.yml"
# Workflow literals, matched verbatim -- no shell expansion intended.
# shellcheck disable=SC2016
BOOTSTRAP_SIGN_LINE=$(grep -n 'Helpers/PTYSessionBootstrap"$' "$RELEASE_WORKFLOW" | head -n 1 | cut -d: -f1)
# shellcheck disable=SC2016
APP_SIGN_LINE=$(grep -n '"\$APP_PATH"$' "$RELEASE_WORKFLOW" | head -n 1 | cut -d: -f1)
[[ -n "$BOOTSTRAP_SIGN_LINE" ]] \
    || fail "release-stable.yml never signs Contents/Helpers/PTYSessionBootstrap"
[[ -n "$APP_SIGN_LINE" && "$BOOTSTRAP_SIGN_LINE" -lt "$APP_SIGN_LINE" ]] \
    || fail "release-stable.yml signs the app bundle before the nested PTYSessionBootstrap"

echo "build-app helpers contract tests passed"
