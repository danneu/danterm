#!/usr/bin/env bash
# Contract tests for release helpers and version-matched resources from build-app.sh.
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

swift run --package-path "$ROOT_DIR" --scratch-path "$TEST_ROOT/layout-tool-build" \
    DanTermBundleLayoutTool release > "$TEST_ROOT/release-layout.json"

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
    "$BUILD_ROOT/integrations/danterm" \
    "$BUILD_ROOT/integrations/shell-integration/vendor" \
    "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly" \
    "$BUILD_ROOT/scripts" \
    "$BUILD_ROOT/themes" \
    "$FAKE_BIN"
ln -s "$ROOT_DIR/build-app.sh" "$BUILD_ROOT/build-app.sh"
cp "$ROOT_DIR/scripts/assemble-app-bundle.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/verify-bundle-layout.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/themes/0x96f.json" "$BUILD_ROOT/themes/"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE"
cp "$ROOT_DIR/app/Info.plist" "$BUILD_ROOT/app/Info.plist"
: > "$BUILD_ROOT/icon/AppIcon/Assets.car"
: > "$BUILD_ROOT/integrations/claude-code/claude-notify-osc777.sh"
: > "$BUILD_ROOT/integrations/claude-code/danterm-agent-session.sh"
: > "$BUILD_ROOT/integrations/codex/danterm-agent-session.sh"
printf '%s\n' '# fixture DanTerm skill' > "$BUILD_ROOT/integrations/danterm/SKILL.md"
for shell in zsh bash fish; do
    printf '# fixture %s integration\n' "$shell" > "$BUILD_ROOT/integrations/shell-integration/danterm.$shell"
done
for vendored in bash-preexec.sh bash-preexec.LICENSE bash-preexec.PROVENANCE; do
    printf '# fixture %s\n' "$vendored" > "$BUILD_ROOT/integrations/shell-integration/vendor/$vendored"
done

# Each shimmed product gets distinct bytes: build-app.sh deliberately fails when
# the GUI and CLI binaries compare equal, and that guard must stay exercisable.
export SWIFT_ARGV_LOG="$TEST_ROOT/swift-argv.log"
export LAYOUT_VERIFY_LOG="$TEST_ROOT/layout-verify.log"
export RELEASE_LAYOUT_PLAN="$TEST_ROOT/release-layout.json"
export REAL_LAYOUT_VERIFIER="$BUILD_ROOT/scripts/verify-bundle-layout.sh"
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
                cat > "$bin_path/DanTermBundleLayoutTool" <<'TOOL'
#!/usr/bin/env bash
[[ "$1" == "release" ]] || exit 2
cat "$RELEASE_LAYOUT_PLAN"
TOOL
                chmod +x "$bin_path/DanTerm" "$bin_path/DanTermCLI" \
                    "$bin_path/DanTermBundleLayoutTool"
                ;;
        esac
        printf '%s\n' "$bin_path"
        ;;
esac
SHIM
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/verify-bundle-layout.sh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAYOUT_VERIFY_LOG"
exec "$REAL_LAYOUT_VERIFIER" "$@"
SHIM
chmod +x "$FAKE_BIN/verify-bundle-layout.sh"

set +e
TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/build-app.sh" --version 0.0.0-test \
    > "$TEST_ROOT/build.out" 2> "$TEST_ROOT/build.err"
status=$?
set -e
[[ $status -eq 0 ]] \
    || fail "build-app.sh failed (status $status): $(cat "$TEST_ROOT/build.err")"
[[ $(wc -l < "$LAYOUT_VERIFY_LOG") -eq 1 ]] \
    || fail "release build did not invoke the bundle-layout verifier exactly once"

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

# Intent: a release producer cannot report success when final bundle verification fails.
# Why it exists: checking the produced files cannot prove that the producer called the verifier.
# Scenario: a PATH shim replaces the verifier with a deterministic failure.
cat > "$FAKE_BIN/verify-bundle-layout.sh" <<'SHIM'
#!/usr/bin/env bash
echo "fixture verifier failure" >&2
exit 42
SHIM
chmod +x "$FAKE_BIN/verify-bundle-layout.sh"
if TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/build-app.sh" --version 0.0.0-test \
    > "$TEST_ROOT/verifier-failure.out" 2> "$TEST_ROOT/verifier-failure.err"; then
    fail "release build ignored a verifier failure"
fi
grep -qF 'fixture verifier failure' "$TEST_ROOT/verifier-failure.err" \
    || fail "release build did not propagate the verifier failure"

rm "$FAKE_BIN/verify-bundle-layout.sh"
cat > "$FAKE_BIN/assemble-app-bundle.sh" <<'SHIM'
#!/usr/bin/env bash
echo "fixture assembler failure" >&2
exit 43
SHIM
chmod +x "$FAKE_BIN/assemble-app-bundle.sh"
if TEST_ROOT="$TEST_ROOT" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/build-app.sh" --version 0.0.0-test \
    > "$TEST_ROOT/assembler-failure.out" 2> "$TEST_ROOT/assembler-failure.err"; then
    fail "release build ignored an assembler failure"
fi
grep -qF 'fixture assembler failure' "$TEST_ROOT/assembler-failure.err" \
    || fail "release build did not propagate the assembler failure"

# Intent: the release bundle preserves the sole authored agent skill byte-for-byte.
# Why it exists: `danterm skill` must report instructions from the same version as
#   the helper even when no agent discovery path is installed.
# Scenario: build-app.sh assembles the production bundle.
cmp "$BUILD_ROOT/integrations/danterm/SKILL.md" \
    "$APP_PATH/Contents/Resources/danterm/SKILL.md" \
    || fail "release bundle did not preserve the canonical DanTerm skill"

# Intent: each workflow verifies a bundle after every signing or ZIP transformation.
# Why it exists: producer verification cannot prove that a later transformation
#   preserves the complete declared layout.
# Scenario: CI ad-hoc signs two bundles and round-trips one through ZIP, while
#   the stable release signs one bundle and round-trips it through ZIP.
[[ $(grep -c 'scripts/verify-bundle-layout.sh' "$ROOT_DIR/.github/workflows/ci.yml") -eq 3 ]] \
    || fail "ci.yml does not verify all three transformed bundles"
[[ $(grep -c 'scripts/verify-bundle-layout.sh' "$ROOT_DIR/.github/workflows/release-stable.yml") -eq 2 ]] \
    || fail "release-stable.yml does not verify both transformed bundles"

CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
CI_FIRST_SIGN_LINE=$(grep -n 'codesign --force --deep --sign - build/DanTerm.app' "$CI_WORKFLOW" | cut -d: -f1)
CI_RELEASE_SIGN_LINE=$(grep -n 'codesign --force --deep --sign - "\$APP_PATH"' "$CI_WORKFLOW" | cut -d: -f1)
CI_UNZIP_LINE=$(grep -n 'unzip -q build/DanTerm-test.zip' "$CI_WORKFLOW" | cut -d: -f1)
CI_FIRST_VERIFY_LINE=$(grep -n 'scripts/verify-bundle-layout.sh' "$CI_WORKFLOW" | sed -n '1s/:.*//p')
CI_SECOND_VERIFY_LINE=$(grep -n 'scripts/verify-bundle-layout.sh' "$CI_WORKFLOW" | sed -n '2s/:.*//p')
CI_THIRD_VERIFY_LINE=$(grep -n 'scripts/verify-bundle-layout.sh' "$CI_WORKFLOW" | sed -n '3s/:.*//p')
[[ -n "$CI_FIRST_SIGN_LINE" && -n "$CI_RELEASE_SIGN_LINE" && -n "$CI_UNZIP_LINE" \
    && "$CI_FIRST_SIGN_LINE" -lt "$CI_FIRST_VERIFY_LINE" \
    && "$CI_RELEASE_SIGN_LINE" -lt "$CI_SECOND_VERIFY_LINE" \
    && "$CI_UNZIP_LINE" -lt "$CI_THIRD_VERIFY_LINE" ]] \
    || fail "ci.yml verifies a bundle before its final transformation"
grep -qF 'build/DanTerm.app .spm-build/bundle-layout-release.json .' "$CI_WORKFLOW" \
    || fail "ci.yml does not verify the ad-hoc signed bundle"
grep -qF '"$APP_PATH" .spm-build/bundle-layout-release.json .' "$CI_WORKFLOW" \
    || fail "ci.yml does not verify the signed release-check bundle"
grep -qF '"$ZIP_WORK/DanTerm.app" .spm-build/bundle-layout-release.json .' "$CI_WORKFLOW" \
    || fail "ci.yml does not verify the ZIP round-trip bundle"

RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release-stable.yml"
RELEASE_SIGN_LINE=$(grep -n -- '--sign "${{ env.SIGNING_IDENTITY }}" "\$APP_PATH"' "$RELEASE_WORKFLOW" | cut -d: -f1)
RELEASE_UNZIP_LINE=$(grep -n 'unzip -q "build/${{ env.ZIP_NAME }}"' "$RELEASE_WORKFLOW" | cut -d: -f1)
RELEASE_FIRST_VERIFY_LINE=$(grep -n 'scripts/verify-bundle-layout.sh' "$RELEASE_WORKFLOW" | sed -n '1s/:.*//p')
RELEASE_SECOND_VERIFY_LINE=$(grep -n 'scripts/verify-bundle-layout.sh' "$RELEASE_WORKFLOW" | sed -n '2s/:.*//p')
[[ -n "$RELEASE_SIGN_LINE" && -n "$RELEASE_UNZIP_LINE" \
    && "$RELEASE_SIGN_LINE" -lt "$RELEASE_FIRST_VERIFY_LINE" \
    && "$RELEASE_UNZIP_LINE" -lt "$RELEASE_SECOND_VERIFY_LINE" ]] \
    || fail "release-stable.yml verifies a bundle before its final transformation"
grep -qF '"$APP_PATH" .spm-build/bundle-layout-release.json .' "$RELEASE_WORKFLOW" \
    || fail "release-stable.yml does not verify the signed app bundle"
grep -qF '"$WORK/${{ env.APP_NAME }}.app" .spm-build/bundle-layout-release.json .' \
    "$RELEASE_WORKFLOW" \
    || fail "release-stable.yml does not verify the ZIP round-trip bundle"

# Nested code must be signed before its container, or the outer signature seals a
# helper whose own signature is then replaced.
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
