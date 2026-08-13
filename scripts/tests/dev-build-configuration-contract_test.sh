#!/usr/bin/env bash
# Contract tests for the dev build scripts' SwiftPM configuration and launcher forwarding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

swift run --package-path "$ROOT_DIR" --scratch-path "$TEST_ROOT/layout-tool-build" \
    DanTermBundleLayoutTool development > "$TEST_ROOT/development-layout.json"

fail() {
    echo "dev-build-configuration-contract_test: $*" >&2
    exit 1
}

BUILD_ROOT="$TEST_ROOT/build-root"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$BUILD_ROOT/lib/TerminalPTY" \
    "$BUILD_ROOT/app" \
    "$BUILD_ROOT/icon/AppIcon-dev" \
    "$BUILD_ROOT/integrations/claude-code" \
    "$BUILD_ROOT/integrations/codex" \
    "$BUILD_ROOT/integrations/danterm" \
    "$BUILD_ROOT/integrations/shell-integration/vendor" \
    "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly" \
    "$BUILD_ROOT/scripts" \
    "$BUILD_ROOT/themes" \
    "$FAKE_BIN"
ln -s "$ROOT_DIR/dev-build.sh" "$BUILD_ROOT/dev-build.sh"
cp "$ROOT_DIR/scripts/assemble-app-bundle.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/verify-bundle-layout.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/sign-app-bundle.sh" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$BUILD_ROOT/scripts/"
cp "$ROOT_DIR/themes/0x96f.json" "$BUILD_ROOT/themes/"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf"
: > "$BUILD_ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE"
cp "$ROOT_DIR/app/Info.plist" "$BUILD_ROOT/app/Info.plist"
: > "$BUILD_ROOT/icon/AppIcon-dev/Assets.car"
: > "$BUILD_ROOT/dev-entitlements.plist"
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

export SWIFT_ARGV_LOG="$TEST_ROOT/swift-argv.log"
export KILLALL_ARGV_LOG="$TEST_ROOT/killall-argv.log"
export LAYOUT_VERIFY_LOG="$TEST_ROOT/layout-verify.log"
export DEVELOPMENT_LAYOUT_PLAN="$TEST_ROOT/development-layout.json"
export REAL_LAYOUT_VERIFIER="$BUILD_ROOT/scripts/verify-bundle-layout.sh"
cat > "$FAKE_BIN/swift" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWIFT_ARGV_LOG"
case " $* " in
    *" --show-bin-path "*)
        case " $* " in
            *"/TerminalPTY "*)
                bin_path="$TEST_ROOT/bootstrap-bin"
                mkdir -p "$bin_path"
                cp /usr/bin/true "$bin_path/PTYSessionBootstrap"
                ;;
            *)
                bin_path="$TEST_ROOT/app-bin"
                mkdir -p "$bin_path"
                printf '#!/bin/sh\n# gui\nexit 0\n' > "$bin_path/DanTerm"
                printf '#!/bin/sh\n# cli\nexit 0\n' > "$bin_path/DanTermCLI"
                printf '#!/bin/sh\n# identity\nexit 0\n' > "$bin_path/DanTermInstanceIdentityTool"
                cat > "$bin_path/DanTermBundleLayoutTool" <<'TOOL'
#!/usr/bin/env bash
[[ "$1" == "development" ]] || exit 2
cat "$DEVELOPMENT_LAYOUT_PLAN"
TOOL
                chmod +x "$bin_path/DanTerm" "$bin_path/DanTermCLI" \
                    "$bin_path/DanTermInstanceIdentityTool" \
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

cat > "$FAKE_BIN/codesign" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$FAKE_BIN/codesign"

cat > "$FAKE_BIN/lsregister" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$FAKE_BIN/lsregister"

cat > "$FAKE_BIN/killall" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KILLALL_ARGV_LOG"
case "$1" in
    -0) exit 1 ;;
esac
exit 0
SHIM
chmod +x "$FAKE_BIN/killall"

run_build() {
    local name="$1"
    shift
    : > "$SWIFT_ARGV_LOG"
    set +e
    HOME="$TEST_ROOT/home-$name" TEST_ROOT="$TEST_ROOT" \
        DANTERM_DEV_LSREGISTER="$FAKE_BIN/lsregister" \
        PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$BUILD_ROOT/dev-build.sh" "$@" \
        > "$TEST_ROOT/$name.out" 2> "$TEST_ROOT/$name.err"
    status=$?
    set -e
    [[ $status -eq 0 ]] \
        || fail "$name build failed (status $status): $(cat "$TEST_ROOT/$name.err")"
    cp "$SWIFT_ARGV_LOG" "$TEST_ROOT/$name.swift-argv"
}

# Intent: the existing no-argument interface continues to select SwiftPM debug builds.
# Why it exists: adding an optimized variant must not slow the normal incremental dev loop.
# Scenario: a developer runs ./dev-build.sh or `just build` without an option.
run_build debug
[[ $(wc -l < "$LAYOUT_VERIFY_LOG") -ge 1 ]] \
    || fail "debug build did not invoke the bundle-layout verifier"
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/themes/catalog.json" ]] \
    || fail "debug bundle omitted the packed theme catalog"
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" ]] \
    || fail "debug bundle omitted the Nerd Font symbols face"
[[ -r "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/NerdFontsSymbolsOnly/LICENSE" ]] \
    || fail "debug bundle omitted the Nerd Font license"
cmp "$BUILD_ROOT/integrations/danterm/SKILL.md" \
    "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/danterm/SKILL.md" \
    || fail "debug bundle did not preserve the canonical DanTerm skill"
for shell in zsh bash fish; do
    cmp "$BUILD_ROOT/integrations/shell-integration/danterm.$shell" \
        "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/shell-integration/danterm.$shell" \
        || fail "debug bundle did not preserve the $shell integration"
done
# danterm.bash sources vendor/bash-preexec.sh relative to its own location, so the
# vendored sibling (and its license/provenance) has to survive the bundle copy too;
# shipping only the three entry points leaves the documented bash path broken.
for vendored in bash-preexec.sh bash-preexec.LICENSE bash-preexec.PROVENANCE; do
    cmp "$BUILD_ROOT/integrations/shell-integration/vendor/$vendored" \
        "$BUILD_ROOT/.build/DanTerm Dev.app/Contents/Resources/shell-integration/vendor/$vendored" \
        || fail "debug bundle did not preserve vendor/$vendored"
done
[[ $(wc -l < "$TEST_ROOT/debug.swift-argv") -eq 4 ]] \
    || fail "debug build did not make four SwiftPM build/bin-path calls"
if grep -q -- '--configuration' "$TEST_ROOT/debug.swift-argv"; then
    fail "default build unexpectedly selected an explicit SwiftPM configuration"
fi

# Intent: --release selects release configuration for both application and helper artifacts.
# Why it exists: a missed build or bin-path call can copy stale debug output into the dev bundle.
# Scenario: a developer requests an optimized DanTerm Dev build for interactive performance work.
run_build release --release
[[ $(wc -l < "$TEST_ROOT/release.swift-argv") -eq 4 ]] \
    || fail "release build did not make four SwiftPM build/bin-path calls"
[[ $(grep -c -- '--configuration release' "$TEST_ROOT/release.swift-argv") -eq 4 ]] \
    || fail "--release was not mapped onto every SwiftPM build/bin-path call"
grep -q -- "--package-path $BUILD_ROOT --build-path .* --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "app and CLI build did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT --build-path .* --show-bin-path --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "app and CLI bin-path lookup did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT/lib/TerminalPTY .* --product PTYSessionBootstrap --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "PTYSessionBootstrap build did not select release configuration"
grep -q -- "--package-path $BUILD_ROOT/lib/TerminalPTY .* --show-bin-path --configuration release$" \
    "$TEST_ROOT/release.swift-argv" \
    || fail "PTYSessionBootstrap bin-path lookup did not select release configuration"

# Intent: a launcher can produce the canonical signed bundle without replacing or
#   terminating the user's installed slot-zero application.
# Why it exists: concurrent development slots are staged from .build, while the user's
#   personal app and its live process must remain untouched.
# Scenario: an agent launcher requests a build-only artifact before cloning its claimed slot.
run_build no-install --no-install
[[ ! -e "$TEST_ROOT/home-no-install/Applications/DanTerm Dev.app" ]] \
    || fail "--no-install replaced the shared install"
[[ ! -s "$KILLALL_ARGV_LOG" ]] \
    || fail "--no-install targeted a running application"

# Intent: a dev producer cannot report success when final bundle verification fails.
# Why it exists: a valid launch does not prove that the producer called the verifier.
# Scenario: a PATH shim replaces the verifier with a deterministic failure.
cat > "$FAKE_BIN/verify-bundle-layout.sh" <<'SHIM'
#!/usr/bin/env bash
echo "fixture verifier failure" >&2
exit 42
SHIM
chmod +x "$FAKE_BIN/verify-bundle-layout.sh"
if HOME="$TEST_ROOT/home-verifier-failure" TEST_ROOT="$TEST_ROOT" \
    DANTERM_DEV_LSREGISTER="$FAKE_BIN/lsregister" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/dev-build.sh" --no-install \
    > "$TEST_ROOT/verifier-failure.out" 2> "$TEST_ROOT/verifier-failure.err"; then
    fail "dev build ignored a verifier failure"
fi
grep -qF 'fixture verifier failure' "$TEST_ROOT/verifier-failure.err" \
    || fail "dev build did not propagate the verifier failure"

rm "$FAKE_BIN/verify-bundle-layout.sh"
cat > "$FAKE_BIN/assemble-app-bundle.sh" <<'SHIM'
#!/usr/bin/env bash
echo "fixture assembler failure" >&2
exit 43
SHIM
chmod +x "$FAKE_BIN/assemble-app-bundle.sh"
if HOME="$TEST_ROOT/home-assembler-failure" TEST_ROOT="$TEST_ROOT" \
    DANTERM_DEV_LSREGISTER="$FAKE_BIN/lsregister" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/dev-build.sh" --no-install \
    > "$TEST_ROOT/assembler-failure.out" 2> "$TEST_ROOT/assembler-failure.err"; then
    fail "dev build ignored an assembler failure"
fi
grep -qF 'fixture assembler failure' "$TEST_ROOT/assembler-failure.err" \
    || fail "dev build did not propagate the assembler failure"

rm "$FAKE_BIN/assemble-app-bundle.sh"
cat > "$FAKE_BIN/verify-bundle-layout.sh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAYOUT_VERIFY_LOG"
exec "$REAL_LAYOUT_VERIFIER" "$@"
SHIM
chmod +x "$FAKE_BIN/verify-bundle-layout.sh"

if HOME="$TEST_ROOT/home-invalid" TEST_ROOT="$TEST_ROOT" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/dev-build.sh" --unknown \
    > "$TEST_ROOT/invalid.out" 2> "$TEST_ROOT/invalid.err"; then
    fail "unknown dev-build.sh option succeeded"
fi
grep -qF 'Usage:' "$TEST_ROOT/invalid.err" \
    || fail "unknown dev-build.sh option did not print usage help"

: > "$KILLALL_ARGV_LOG"
HOME="$TEST_ROOT/home-install" TEST_ROOT="$TEST_ROOT" \
    DANTERM_DEV_LSREGISTER="$FAKE_BIN/lsregister" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$BUILD_ROOT/dev-build.sh" --kill-running \
    > "$TEST_ROOT/install.out" 2> "$TEST_ROOT/install.err"
grep -qFx 'DanTerm Dev' "$KILLALL_ARGV_LOG" \
    || fail "install did not terminate exactly the slot-zero executable"
grep -qFx -- '-0 DanTerm Dev' "$KILLALL_ARGV_LOG" \
    || fail "install did not poll the literal slot-zero executable name"

RUN_ROOT="$TEST_ROOT/run-root"
mkdir -p "$RUN_ROOT"
ln -s "$ROOT_DIR/dev-build-run.sh" "$RUN_ROOT/dev-build-run.sh"
export RUN_BUILD_LOG="$TEST_ROOT/run-build.log"
cat > "$RUN_ROOT/dev-build.sh" <<'SHIM'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" > "$RUN_BUILD_LOG"
SHIM
chmod +x "$RUN_ROOT/dev-build.sh"
cat > "$FAKE_BIN/open" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$FAKE_BIN/open"

# Intent: the build-and-run wrapper forwards its configuration flag through while
# requesting that the build stop the installed app immediately before replacing its bundle.
# Why it exists: relaunch must not race an old process that still has the previous
# bundle open.
# Scenario: a developer launches an optimized build from one command.
HOME="$TEST_ROOT/run-home" \
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$RUN_ROOT/dev-build-run.sh" --release
grep -qFx 'argv=--release --kill-running' "$RUN_BUILD_LOG" \
    || fail "dev-build-run.sh did not forward --release and append --kill-running"

echo "dev build configuration contract tests passed"
